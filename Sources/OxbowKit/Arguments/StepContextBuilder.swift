import Foundation

/// Builds a step's `StepContext`: where it works, where it writes, what it
/// reads, and — for a composite — where it resumes from.
///
/// Beside `StepContext` and `ArgumentBuilder` deliberately. `ArgumentBuilder`
/// is pure and does no I/O; every filesystem decision those arguments depend
/// on is made here and handed across as a value. That division is why
/// `StepContext` carries `hasUsableSidecar` and `chatResumeFrom` as plain
/// fields rather than as something the argument builder works out for itself.
///
/// A `Sendable` struct over immutable state, so it has no isolation of its
/// own and `make` stays synchronous — the engine calls it from `launch`,
/// which must not acquire a suspension point between deciding to launch a
/// step and marking it `.running`.
struct StepContextBuilder: Sendable {
  private let workspace: Workspace
  private let ffmpegPath: URL
  private let ledger: ResumeLedger
  private let journal: TeardownJournal

  init(
    workspace: Workspace,
    ffmpegPath: URL,
    ledger: ResumeLedger,
    journal: TeardownJournal)
  {
    self.workspace = workspace
    self.ffmpegPath = ffmpegPath
    self.ledger = ledger
    self.journal = journal
  }

  /// Builds a step's `StepContext`: where it works, where it writes, and
  /// (for a composite) where it resumes from.
  ///
  /// A `Sendable` struct over immutable state, so this has no isolation of
  /// its own and needs no `await` — which also happens to be what lets tests
  /// exercise it directly, with no engine involved.
  func make(job: Job, step: Step) throws -> StepContext {
    let stepDirectory = try workspace.prepareStep(job: job.id, step: step.id)
    let artifacts = try workspace.prepareArtifacts(job: job.id)

    // The CLI infers download type from the output file extension.
    let name: String = switch step.kind {
    case .downloadVideo: "video.mp4"
    case .downloadClip: "clip.mp4"
    case .downloadChat(let request): "chat.\(request.format.rawValue)"
    case .renderChat: "render.mp4"
    case .composite: "composite.mp4"
    case .assemble: "assemble.mp4"
    }

    // Order-preserving: `Step.dependsOn` is ordered and the argument builder
    // reads these positionally.
    let inputs = step.dependsOn.compactMap { dependency in
      job.steps.first { $0.id == dependency }?.artifact
    }

    // `compactMap` silently drops a missing artifact, which would otherwise
    // shift every later positional input down by one — a composite reading
    // its chat render as `input 0` because the video's artifact went missing.
    // That surfaces as a baffling FFmpeg error (wrong stream mapped, or a
    // filter given too few inputs) far from its real cause: a step ran with a
    // parent that was not actually `.done`, which should never happen given
    // `Scheduler.admissible`'s guard, but a future regression there should be
    // loud here rather than silently mis-wired.
    guard inputs.count == step.dependsOn.count else {
      throw StepWiringError(
        "step \(step.id) expected \(step.dependsOn.count) input artifact(s) "
          + "but only \(inputs.count) parent(s) had one")
    }

    if case .composite(let request) = step.kind {
      // `resumePoint` first: past the cap it removes the retained directory
      // entirely, and `prepareResume` recreates it — empty — right after, so
      // `directory` names a real, empty directory either way. Calling these
      // in the other order would hand back a piece path inside a directory
      // that no longer exists once the cap resets it.
      let resume = ledger.resumePoint(job: job.id, framerate: request.framerate)
      let directory = try workspace.prepareResume(job: job.id)

      // A resumed job re-downloads its source, and Twitch does not guarantee
      // it comes back the same: sections get muted for DMCA after the fact,
      // renditions get re-encoded, VODs get trimmed. Half a composite from
      // before such a change and half from after produces a file with a
      // discontinuity and no error anywhere — the encode succeeds, the join
      // succeeds, and the video is quietly wrong. Byte length plus duration
      // catches that: two real downloads of the same VOD were measured
      // byte-for-byte different but identical in both of these, so a mismatch
      // here means the source itself changed, not just re-encoding noise. See
      // docs/design/resume.md §7.
      let fingerprintFile = directory.appending(path: "source.json")
      let sourceVideo = inputs.first
      if let sourceVideo {
        let fresh = try SourceFingerprint.of(sourceVideo, duration: request.duration)
        if resume.from == nil {
          try? fresh.write(to: fingerprintFile)
        } else {
          // Fail closed, not open. A full disk is the likeliest reason the
          // composite failed at all, and also the likeliest reason
          // `source.json` itself failed to write on the first attempt or
          // fails to read back now — so "cannot verify" must refuse exactly
          // like "verified, and it disagrees" (§7: refuses rather than
          // repairs). Treating a missing or unreadable fingerprint as an
          // implicit match would resume unverified in precisely the
          // situation this check exists to catch.
          guard let recorded = try? SourceFingerprint.read(from: fingerprintFile) else {
            throw SourceChangedError(reason:
              "This download's earlier attempt could not be verified — its "
                + "recorded source fingerprint is missing or unreadable. Start it again.")
          }
          guard recorded.matches(fresh) else {
            throw SourceChangedError()
          }
        }
      }

      // "Exists and is non-empty" is not enough — a `SIGKILL` mid-write
      // leaves a non-empty file with no `moov`. `hasCompleteMoov` is the same
      // no-decode box walk `FragmentIndex` already uses for pieces, applied
      // to the one file on this path that is deliberately *not* fragmented.
      // Any I/O failure here (missing file, unreadable) is "not usable" —
      // the safe default, since the cost of a spurious rewrite is a cheap
      // stream copy, while treating a corrupt sidecar as usable is the exact
      // defect this fix closes. resume.md §4.
      let sidecarFile = directory.appending(path: "audio.m4a")
      let hasUsableSidecar = FileManager.default.fileExists(atPath: sidecarFile.path)
        && ((try? FragmentedMP4.hasCompleteMoov(at: sidecarFile)) ?? false)

      // A chat render does not always run as long as its video — renders end
      // at the last message — so a resume point can land past the end of the
      // render while the video still has most of an hour left. Seeking the
      // render there yields zero frames, `hstack` has no last frame to
      // repeat, and the composite writes an empty piece and exits 0. Clamping
      // to one frame inside the render's end lands the seek on its last frame
      // instead, which is exactly what a first attempt shows at that point.
      //
      // `nil` whenever the answer is not both known and needed: no resume, no
      // render input, an unreadable header, or a render long enough to seek
      // into normally. All four mean "seek the chat with the video", which is
      // the behaviour that was always correct for them. resume.md §12.
      // The margin is measured in the *render's* frames, never the
      // composite's. They are routinely different — the filter graph exists
      // partly to normalise a 30fps render up to a 60fps video — and getting
      // this wrong is silent: a margin of one 60fps frame (0.0167s) lands
      // past the last frame of a 30fps render, whose final frame sits
      // 0.0333s before the end, so the seek yields nothing and the piece
      // comes out empty exactly as if there had been no clamp at all. That
      // is not hypothetical; it is what the first version of this did.
      //
      // Two frames rather than one, so a frame of rounding either way still
      // lands inside. The cost is that the seam replays two frames of chat
      // (67ms at 30fps) instead of freezing on the last one; the cost of
      // being one frame too late is the whole tail of the delivery.
      let renderFramerate: Int? = step.dependsOn.count > 1
        ? job.steps.first { $0.id == step.dependsOn[1] }.flatMap {
            if case .renderChat(let render) = $0.kind { render.framerate } else { nil }
          }
        : nil
      let chatResumeFrom: Duration? = {
        guard let from = resume.from, inputs.count > 1,
              let renderLength = try? FragmentedMP4.duration(of: inputs[1])
        else { return nil }
        // No render framerate to be had means no basis for a frame-sized
        // margin, so fall back to a quarter second — comfortably more than
        // one frame at any rate a chat is rendered at, and still a seam
        // artefact nobody can see.
        let margin = renderFramerate.map { 2.0 / Double($0) } ?? 0.25
        let landing = renderLength - .seconds(margin)
        guard landing > .zero, from > landing else { return nil }
        return landing
      }()

      return StepContext(
        stepTempDirectory: stepDirectory,
        outputFile: directory.appending(path: "piece-\(resume.index).mp4"),
        ffmpegPath: ffmpegPath,
        inputArtifacts: inputs,
        resumeFrom: resume.from,
        chatResumeFrom: chatResumeFrom,
        hasUsableSidecar: hasUsableSidecar,
        log: StepLog(fileURL: workspace.logFile(job: job.id, step: step.id)))
    }

    if case .assemble = step.kind {
      // The concat demuxer reads a list file. Written here rather than in
      // ArgumentBuilder because that type is pure and does no I/O.
      let list = ledger.pieces(of: job.id)
        .map { "file '\($0.path)'" }
        .joined(separator: "\n") + "\n"
      try list.write(
        to: stepDirectory.appending(path: "pieces.txt"), atomically: true, encoding: .utf8)

      // The re-fetched video and chat render are both dead once the pieces
      // and the sidecar audio exist. Dropping them here rather than at job
      // end is what keeps the recovery peak near a normal run's — resume.md
      // §5. Scoped to this job's workspace so nothing outside it can be hit.
      let spent = job.steps.compactMap { step -> URL? in
        switch step.kind {
        case .downloadVideo, .downloadClip, .renderChat: step.artifact
        case .downloadChat, .composite, .assemble: nil
        }
      }
      let unremoved = spent
        .filter { workspace.contains($0, ofJob: job.id) }
        .compactMap { file -> URL? in
          do {
            try FileManager.default.removeItem(at: file)
            return nil
          } catch {
            return file
          }
        }
      journal.record(
        unremoved, context: "job \(job.id.rawValue.uuidString): re-fetched inputs spent by assemble")

      // Assemble's single input artifact is the sidecar audio, not a parent's
      // output — everything else it needs is in the retention area and named
      // by convention. `ArgumentBuilder` stays pure by being handed the path.
      return StepContext(
        stepTempDirectory: stepDirectory,
        outputFile: artifacts.appending(path: name),
        ffmpegPath: ffmpegPath,
        inputArtifacts: [workspace
          .resumeDirectory(job.id).appending(path: "audio.m4a")],
        log: StepLog(fileURL: workspace.logFile(job: job.id, step: step.id)))
    }

    return StepContext(
      stepTempDirectory: stepDirectory,
      outputFile: artifacts.appending(path: name),
      ffmpegPath: ffmpegPath,
      inputArtifacts: inputs,
      log: StepLog(fileURL: workspace.logFile(job: job.id, step: step.id)))
  }
}

/// Thrown when a resumed job's re-downloaded source no longer matches what
/// piece 0 was built from — or when that comparison could not be made at
/// all. See docs/design/resume.md §7.
struct SourceChangedError: Error {
  /// Set only when refusing because the fingerprint could not be read back,
  /// rather than because it was read and disagreed with the fresh one. The
  /// two need different words: "the source changed" overstates what is
  /// actually known when the fingerprint itself is the thing missing. `nil`
  /// falls back to the ordinary mismatch message at the catch site.
  let reason: String?

  init(reason: String? = nil) {
    self.reason = reason
  }
}

/// Thrown by `StepContextBuilder.make` when a step's resolved input artifacts
/// are shorter than its `dependsOn`, so `launch` can report a wiring bug
/// distinctly from an ordinary working-directory failure.
struct StepWiringError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
