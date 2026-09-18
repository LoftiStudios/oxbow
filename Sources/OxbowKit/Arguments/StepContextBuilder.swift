import Foundation

/// Resolve filesystem-dependent step arguments synchronously so launch can mark running without
/// suspension. Creates directories and concat lists but deletes no inputs; destructive cleanup
/// belongs to TeardownJournal.
struct StepContextBuilder: Sendable {
  private let workspace: Workspace
  private let ffmpegPath: URL
  private let ledger: ResumeLedger

  init(workspace: Workspace, ffmpegPath: URL, ledger: ResumeLedger) {
    self.workspace = workspace
    self.ffmpegPath = ffmpegPath
    self.ledger = ledger
  }

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

    // Reject missing dependency artifacts rather than letting compactMap shift positional
    // inputs. Scheduler should prevent this; report violations as wiring errors.
    guard inputs.count == step.dependsOn.count else {
      throw StepWiringError(
        "step \(step.id) expected \(step.dependsOn.count) input artifact(s) "
          + "but only \(inputs.count) parent(s) had one")
    }

    if case .composite(let request) = step.kind {
      // Resolve the resume point before preparing directories: hitting the piece cap removes
      // retention, so preparing first would return paths in a deleted directory.
      let resume = ledger.resumePoint(job: job.id, framerate: request.framerate)
      let directory = try workspace.prepareResume(job: job.id)

      // Compare re-downloaded source size and duration with piece zero's fingerprint before
      // resuming. Twitch may mute or alter a source; mismatched halves would otherwise encode
      // and assemble without error. See docs/design/resume.md §7.
      let fingerprintFile = directory.appending(path: "source.json")
      let sourceVideo = inputs.first
      if let sourceVideo {
        let fresh = try SourceFingerprint.of(sourceVideo, duration: request.duration)
        if resume.from == nil {
          try? fresh.write(to: fingerprintFile)
        } else {
          // Refuse missing or unreadable fingerprints as well as mismatches. A full disk can
          // prevent writing the fingerprint during the very failure being resumed.
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

      // A non-empty sidecar may lack moov after SIGKILL. Treat read failures as unusable and
      // rewrite; a stream copy is safer than trusting incomplete audio.
      let sidecarFile = directory.appending(path: "audio.m4a")
      let hasUsableSidecar = FileManager.default.fileExists(atPath: sidecarFile.path)
        && ((try? FragmentedMP4.hasCompleteMoov(at: sidecarFile)) ?? false)

      // Clamp a resume beyond a short render's end so hstack gets a frame to repeat. Use two
      // render frames, not composite frames, to allow rounding and differing rates. Without
      // this, FFmpeg can exit 0 with an empty piece. No known/needed clamp means use the video
      // seek. See docs/design/resume.md §12.
      let renderFramerate: Int? = step.dependsOn.count > 1
        ? job.steps.first { $0.id == step.dependsOn[1] }.flatMap {
            if case .renderChat(let render) = $0.kind { render.framerate } else { nil }
          }
        : nil
      let chatResumeFrom: Duration? = {
        guard let from = resume.from, inputs.count > 1,
              let renderLength = try? FragmentedMP4.duration(of: inputs[1])
        else { return nil }
        // Without a render framerate, use a quarter-second safety margin.
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
      // Write the concat list here to keep ArgumentBuilder free of I/O.
      let list = ledger.pieces(of: job.id)
        .map { "file '\($0.path)'" }
        .joined(separator: "\n") + "\n"
      try list.write(
        to: stepDirectory.appending(path: "pieces.txt"), atomically: true, encoding: .utf8)

      // Assemble's artifact input is sidecar audio; retained pieces are named separately by
      // convention.
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
  /// Distinguish an unreadable fingerprint from a verified mismatch; nil uses the mismatch
  /// message.
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
