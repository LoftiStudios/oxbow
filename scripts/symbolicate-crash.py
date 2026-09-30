#!/usr/bin/env python3
"""Symbolicate the crash trace in an Oxbow crash-report issue.

Oxbow's crash banner opens an issue whose trace names Oxbow's own frames only
as offsets (docs/design/crash-reports.md). This downloads the dSYM attached to
that version's release, checks it is the build that crashed, and turns those
offsets back into functions and lines.

    scripts/symbolicate-crash.py 123            # print the result
    scripts/symbolicate-crash.py 123 --post     # post it as a comment

Run by .github/workflows/symbolicate-crash.yml when an issue is opened. macOS
only: atos, dwarfdump and ditto come with Xcode.

The issue body is written by whoever opened the issue, so it is untrusted:
nothing from it reaches a shell, and the only values taken from it are a
version and a UUID, each checked against a strict pattern before use.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile

# The footer CrashIssue writes. Its absence means this is not a crash report.
MARKER = "Filled in by Oxbow from the crash report"
# Written on the comment, so a re-run does not post twice.
COMMENT_MARKER = "<!-- oxbow-symbolicated -->"

VERSION = re.compile(r"^Oxbow (\d+\.\d+\.\d+) \(\d+\) · ", re.M)
UUID = re.compile(
    r"^Oxbow binary: `([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})`$", re.M)
# The space after the number is optional: 0.6.0 wrote frame 100 onwards as
# "100Oxbow  + 12". No binary name starts with a digit, so the split is safe.
FRAME = re.compile(r"^(\d+) *(\D.*?) +\+ (\d+)$")

# Oxbow's __TEXT segment is linked at this address, and MetricKit's offsets are
# relative to the start of it.
TEXT_BASE = 0x100000000

DEFAULT_REPO = "LoftiStudios/oxbow"


def parse(body):
    """The version, UUID and frames of a crash-report body, or None."""
    if MARKER not in body:
        return None
    version = VERSION.search(body)
    uuid = UUID.search(body)
    frames = []
    in_trace = False
    for line in body.splitlines():
        if line.strip() == "Crashed thread:":
            in_trace = True
            continue
        if in_trace and line.startswith("```"):
            if frames:
                break
            continue
        if in_trace:
            match = FRAME.match(line.rstrip())
            if match:
                frames.append((line.rstrip(), match.group(2), int(match.group(3))))
            elif line.startswith("…"):
                frames.append((line.rstrip(), None, None))
    return {
        "version": version.group(1) if version else None,
        "uuid": uuid.group(1).upper() if uuid else None,
        "frames": frames,
    }


def render(report, names, note):
    """The comment: the trace with Oxbow's frames named, under a one-line note."""
    lines = [COMMENT_MARKER, note, "", "```"]
    width = max((len(b) for _, b, _ in report["frames"] if b), default=0)
    for text, binary, offset in report["frames"]:
        name = names.get(offset) if binary == "Oxbow" else None
        if name:
            number = FRAME.match(text).group(1)
            lines.append(f"{(number + ' ').ljust(3)}{'Oxbow'.ljust(width)}  {name}")
        else:
            lines.append(text)
    lines += ["```", "",
              "<sub>Posted by `.github/workflows/symbolicate-crash.yml`. System frames stay "
              "as offsets: Apple does not publish their symbols, and the library name is "
              "usually enough.</sub>"]
    return "\n".join(lines)


def comment_for(body, fetch_dsym, symbolicate):
    """What to post for an issue body, or None when it is not a crash report.

    fetch_dsym(version) -> path to the DWARF file, or None.
    symbolicate(dwarf, uuid, offsets) -> {offset: name}, or None on a UUID mismatch.
    """
    report = parse(body)
    if report is None:
        return None
    if not report["version"] or not report["uuid"]:
        # A DEBUG build names its frames Oxbow.debug.dylib, so it carries no UUID.
        return render(report, {},
                      "Could not symbolicate: this report names no release version or "
                      "Oxbow binary UUID, which usually means a development build.")
    dwarf = fetch_dsym(report["version"])
    if dwarf is None:
        return render(report, {},
                      f"Could not symbolicate: no dSYM is attached to the "
                      f"v{report['version']} release. Releases before dSYMs were kept "
                      f"cannot be symbolicated.")
    offsets = sorted({o for _, b, o in report["frames"] if b == "Oxbow"})
    names = symbolicate(dwarf, report["uuid"], offsets)
    if names is None:
        return render(report, {},
                      f"Could not symbolicate: the v{report['version']} dSYM does not match "
                      f"binary `{report['uuid']}`, so this build is not the one released.")
    return render(report, names,
                  f"Symbolicated with the dSYM from v{report['version']} "
                  f"(`{report['uuid']}` matches).")


# ---------------------------------------------------------------- real tools

def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def fetch_dsym(repo, version, workdir):
    zip_name = f"Oxbow-{version}-arm64.dSYM.zip"
    try:
        run("gh", "release", "download", f"v{version}", "--repo", repo,
            "--pattern", zip_name, "--dir", str(workdir))
    except subprocess.CalledProcessError:
        return None
    run("ditto", "-x", "-k", str(workdir / zip_name), str(workdir))
    dwarf = workdir / "Oxbow.app.dSYM" / "Contents" / "Resources" / "DWARF" / "Oxbow"
    return dwarf if dwarf.exists() else None


def symbolicate(dwarf, uuid, offsets):
    # "UUID: 8C3A5A96-... (arm64) /path": the slice that matches decides the arch.
    arch = None
    for line in run("dwarfdump", "--uuid", str(dwarf)).splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1].upper() == uuid:
            arch = parts[2].strip("()")
    if arch is None:
        return None
    if not offsets:
        return {}
    addresses = [hex(TEXT_BASE + o) for o in offsets]
    out = run("atos", "-arch", arch, "-o", str(dwarf), "-l", hex(TEXT_BASE), *addresses)
    names = {}
    for offset, line in zip(offsets, out.splitlines()):
        line = line.strip()
        # atos echoes an address it cannot resolve.
        if line and not line.startswith("0x"):
            names[offset] = line.replace(" (in Oxbow)", "")
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("issue", type=int)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--post", action="store_true", help="post the result as a comment")
    args = parser.parse_args()

    issue = json.loads(run("gh", "issue", "view", str(args.issue), "--repo", args.repo,
                           "--json", "body,comments"))
    if args.post and any(COMMENT_MARKER in c.get("body", "") for c in issue["comments"]):
        print(f"#{args.issue} is already symbolicated.")
        return

    with tempfile.TemporaryDirectory() as tmp:
        comment = comment_for(
            issue["body"] or "",
            lambda version: fetch_dsym(args.repo, version, pathlib.Path(tmp)),
            symbolicate)

    if comment is None:
        print(f"#{args.issue} is not an Oxbow crash report.")
        return
    if args.post:
        run("gh", "issue", "comment", str(args.issue), "--repo", args.repo,
            "--body-file", "-", input=comment)
        print(f"Commented on #{args.issue}.")
    else:
        print(comment)


if __name__ == "__main__":
    sys.exit(main())
