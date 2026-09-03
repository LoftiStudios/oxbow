#!/usr/bin/env swift
//
// Print the CGWindowID of an on-screen window, for `screencapture -l`.
//
// `screencapture` has exactly one non-interactive way to capture a single
// window — `-l<windowid>` — and no way to name that window. Everything else it
// offers is either interactive (`-i`, `-w`) or a screen rectangle (`-R`),
// which loses the rounded corners and picks up whatever is behind the window.
// So something has to turn "that app's window" into a number.
//
// Usage:  window-id.swift <pid> [title-substring]
// Prints the id to stdout, or exits 1 with a diagnostic listing what it did see.
//
// Matching is by PID, not by application name, and that is load-bearing. The
// screenshot run launches a second Oxbow alongside whatever the developer
// already has open, because `Contents/MacOS/Oxbow` bypasses LaunchServices and
// genuinely starts a new process. Matching on the name "Oxbow" found the
// developer's real window first and captured a queue full of real streamers —
// silently, since the image looked perfectly correct. A PID cannot be
// ambiguous that way.
//
// Screen Recording permission: CGWindowListCopyWindowInfo omits kCGWindowName
// for other processes unless the calling binary holds it. `screencapture`
// needs the same permission, so a run that can capture can generally also read
// titles — but the two are granted to different binaries (Terminal vs. this
// script's interpreter), so they can disagree. When the title is missing this
// falls back to the largest normal-layer window owned by the app, which for
// Oxbow is the queue window and is right often enough to be worth having
// rather than failing outright.

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2, let wantedPID = Int(arguments[1]) else {
  FileHandle.standardError.write(Data("usage: window-id.swift <pid> [title]\n".utf8))
  exit(2)
}
let wantedTitle = arguments.count > 2 ? arguments[2] : nil

guard
  let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                       kCGNullWindowID) as? [[String: Any]]
else {
  FileHandle.standardError.write(Data("could not read the window list\n".utf8))
  exit(1)
}

struct Candidate {
  let id: CGWindowID
  let title: String
  let area: CGFloat
}

var candidates: [Candidate] = []
var sawOwner = false

for window in raw {
  guard (window[kCGWindowOwnerPID as String] as? Int) == wantedPID else { continue }
  sawOwner = true
  // Layer 0 is a normal window. Panels, menus and the like sit above it and
  // would otherwise win the largest-window fallback at odd moments.
  guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
  guard let id = window[kCGWindowNumber as String] as? CGWindowID else { continue }

  let title = (window[kCGWindowName as String] as? String) ?? ""
  var area: CGFloat = 0
  if
    let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
    let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
  {
    area = bounds.width * bounds.height
  }
  candidates.append(Candidate(id: id, title: title, area: area))
}

guard !candidates.isEmpty else {
  let message = sawOwner
    ? "pid \(wantedPID) is running but has no normal on-screen window yet\n"
    : "no on-screen window owned by pid \(wantedPID)\n"
  FileHandle.standardError.write(Data(message.utf8))
  exit(1)
}

if let wantedTitle, !wantedTitle.isEmpty {
  // Exact before substring, and it is load-bearing. A `WindowGroup(for:)`
  // window is briefly titled with the application name before its content
  // applies its own title, so while Job Info is settling there are two windows
  // whose title contains "Oxbow" -- and a substring match would happily return
  // the wrong one. Which it did: the queue capture came back 460x620, Job
  // Info's default size, looking like a perfectly ordinary screenshot.
  if let exact = candidates.first(where: { $0.title == wantedTitle }) {
    print(exact.id)
    exit(0)
  }
  if let match = candidates.first(where: { $0.title.contains(wantedTitle) }) {
    print(match.id)
    exit(0)
  }
  // Titles are readable but none matched: a genuine miss, worth naming.
  if candidates.contains(where: { !$0.title.isEmpty }) {
    let seen = candidates.map { "  \($0.id)  \"\($0.title)\"" }.joined(separator: "\n")
    FileHandle.standardError.write(Data("""
      no window of pid \(wantedPID) titled containing \"\(wantedTitle)\". Saw:
      \(seen)

      """.utf8))
    exit(1)
  }
}

// Either no title was asked for, or none are readable. Largest wins.
let fallback = candidates.max { $0.area < $1.area }!
print(fallback.id)
