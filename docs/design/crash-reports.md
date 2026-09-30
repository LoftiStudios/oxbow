# Crash reports

Oxbow collects nothing on its own. When it crashes, the next launch offers
to open a GitHub issue with the crash filled in, and the user decides whether
to submit it.

## 1. Why not a crash service

Xcode's Organizer only receives crashes from App Store and TestFlight
installs; Oxbow ships as a notarized DMG, so it would receive nothing.
Hosted services (Sentry, Crashlytics, Bugsnag) would work, but each is a
third-party SDK sending data off the user's Mac, which needs a privacy
policy, an opt-in, and an account. That is a lot of apparatus for an app of
this size, and it would put reports somewhere other than the issue tracker
the project already works from.

What is lost: a crash rate. Oxbow only hears about crashes people choose to
report. At this size that is an acceptable trade.

## 2. How it works

`CrashReporter` subscribes to MetricKit at launch. On the launch after a
crash, macOS delivers an `MXCrashDiagnostic` for it: the call stack of every
thread, the exception, the signal, and the app and OS versions. This works
the same for a Developer ID build as for an App Store one, needs no server,
and arrives within a second of launch.

`CrashReport` (OxbowKit) decodes the diagnostic's JSON form and
`CrashIssue` turns it into a `issues/new` link with a title and a body. The
banner opens that link. Opening it sends nothing: the user sees the whole
report in GitHub's own form, adds what they were doing, and submits it or
doesn't.

The report is held in memory only. MetricKit delivers a crash once, so a
report nobody acts on before quitting again is gone. That is deliberate:
a banner that survives launches nags about a crash the user has already
decided not to report.

**The subscriber must not be main-actor isolated.** The app target defaults
to the main actor, and MetricKit calls `didReceive` on a background queue.
An isolated subscriber fails Swift's executor check and traps, and because
that happens on the launch *after* a crash, the app then crashes on every
launch. That is how this was first built. The test fixture is that crash.

## 3. What the issue carries

- Oxbow's version and build, the macOS version, the Mac model.
- The exception and signal, e.g. `EXC_BAD_ACCESS (SIGSEGV)`, and an
  Objective-C exception's message when there is one.
- The crashed thread as `binary + offset`, innermost frame first.
- The UUID of Oxbow's own binary.

No file paths, no queue contents, no channel names. The trace is addresses
only.

GitHub answers 414 to a URL much past 8 KB, so `CrashIssue` drops frames from
the outermost end until the link fits. The innermost frames are the ones that
matter.

## 4. Reading a report

Oxbow's frames arrive as offsets into a binary with no symbols. The dSYM
attached to each GitHub release turns them back into functions. It has to be
the dSYM from *that* release, because a rebuild of the same commit gets a
different UUID.

**This happens on its own.** `.github/workflows/symbolicate-crash.yml` runs
when an issue is opened. If the body carries the footer `CrashIssue` writes,
it runs `scripts/symbolicate-crash.py`, which downloads the release's dSYM,
checks the UUID, and comments with Oxbow's frames named. When it cannot (no
dSYM on that release, a UUID from another build, or a development build), it
says which in the comment instead. Run it by hand on any issue:

```bash
./scripts/symbolicate-crash.py 123
```

It prints the comment without posting it; `--post` posts it. To re-run the
workflow on an issue filed before it existed, use its "Run workflow" button
with the issue number.

The script parses the body `CrashIssue` writes, so the two are pinned to one
file, `Tests/OxbowKitTests/Fixtures/crash-issue-body.md`. The Swift test
checks `CrashIssue` still produces it and the Python test parses it. Change
the format and both go red until the file is regenerated
(`OXBOW_WRITE_GOLDEN=1 swift test --filter CrashIssue`) and the script agrees.

By hand, check the UUID in the issue against the dSYM:

```bash
dwarfdump --uuid Oxbow.app.dSYM
```

Then symbolicate each `Oxbow + <offset>` frame. Oxbow's text segment is
loaded at `0x100000000`, so the address is that plus the offset:

```bash
atos -arch arm64 -o Oxbow.app.dSYM/Contents/Resources/DWARF/Oxbow -l 0x100000000 $(printf '0x%x' $((0x100000000 + 50488)))
```

System frames (`AppKit`, `SwiftUI`, `libdispatch.dylib`) need no dSYM from
us. The library name and the surrounding Oxbow frames are usually enough.

## 5. Trying it

DEBUG builds have **Debug › Crash Oxbow**. Choose it, relaunch Oxbow, and the
banner appears within a second or two.
