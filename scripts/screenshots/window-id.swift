#!/usr/bin/env swift
// Prints a window ID for `screencapture -l`. Usage: `window-id.swift <pid> [title-substring]`;
// exits 1 with diagnostics if absent. Match PID, not app name, to avoid capturing the user's
// separate Oxbow instance. Missing Screen Recording permission can hide titles; fall back to
// the process's largest normal-layer window.

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
  // Prefer exact titles: a newly opening window may briefly share the app name and otherwise
  // win a substring match.
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
