#!/usr/bin/env python3
"""
Build the screenshot fixture from a real queue.json.

Why a transform rather than a hand-written file: queue.json is Swift's default
Codable encoding of enums with associated values, so a step kind looks like
`{"downloadChat": {"_0": {...}}}` and a Duration is a 128-bit attosecond pair
split across two Int64s. That is unpleasant to author by hand and easy to get
subtly wrong in a way that only shows up as an empty queue at launch. Starting
from a file the app itself wrote means the shape is right by construction.

It also means this survives schema changes. When Job or Step gain a field, run
the app once, point this at the queue.json it wrote, and the fixture is current
again -- no format knowledge here to update, beyond the handful of key names
below that carry identifying data.

What gets replaced, and why each one:

  title           the only string a reader sees. Real ones name real streamers.
  videoID         Twitch ids resolve to real VODs.
  clipSlug        likewise.
  destination     absolute file:// URLs carrying /Users/<you>.
  artifact        same.
  id.rawValue     random UUIDs, so a regenerated fixture would show a spurious
                  diff on every run. Made deterministic instead.
  created         real timestamps. Not what orders the list — QueueView
                  draws controller.jobs in array order — but still real.

Usage:
    ./make-fixture.py                       # from the live app's queue.json
    ./make-fixture.py path/to/queue.json    # from a specific one
"""

import json
import os
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "fixture" / "queue.json"

DEFAULT_SOURCE = Path.home() / "Library/Application Support/studio.lofti.Oxbow/queue.json"

# A fictional cast, reused from the chat mockup so the demo data has one
# identity across every artifact the project publishes. Format matches
# OutputNaming: "{streamer} - {date} - {title}".
TITLES = [
    "CrashOverride - 2026-08-11 - death stranding ep. 3 - BT country, send help",
    "CrashOverride - 2026-08-12 - death stranding ep. 4 - crossing the tar belt",
    "AcidBurn - 2026-08-01 - persona 3 - first playthrough, blind, no spoilers 🌙",
    "AcidBurn - 2026-08-02 - persona 3 - exam week and i am not prepared 😭📚",
    "AcidBurn - 2026-08-03 - persona 3 - tartarus grind + social links",
    "AcidBurn - 2026-08-04 - persona 3 - full moon op, wish us luck 🌕",
]

# Which job is caught mid-flight, and what its steps are doing. An all-done
# queue is a truthful screenshot of a boring moment; the interesting one shows
# the multi-step model actually working. Index into the job list.
RUNNING_JOB = 5

# The intake shows a video being *added*, so deliberately not one of the six
# already queued: the next episode after the one downloading at the bottom.
# `createdAt` is absolute so a composite of the two windows still agrees with
# itself next month.
INTAKE = {
    "streamer": "AcidBurn",
    "title": "persona 3 - ep. 5 - the answer, and then bed 🌒",
    "createdAt": "2026-08-05T20:14:00Z",
    "durationSeconds": 8142,
    "qualities": [
        {"name": "1080p60", "resolution": "1920x1080", "bitsPerSecond": 6_184_466},
        {"name": "720p60", "resolution": "1280x720", "bitsPerSecond": 3_411_940},
        {"name": "480p30", "resolution": "852x480", "bitsPerSecond": 1_427_697},
    ],
    # Served over http by scripts/screenshots.sh, never file:// — VideoCard
    # requires an HTTPURLResponse with status 200, so a file URL silently
    # renders the placeholder instead.
    "thumbnailPaths": ["thumbnail.jpg"],
}
INTAKE_LINK = "https://www.twitch.tv/videos/2850120005"
RUNNING_PLAN = {
    "downloadChat": ("done", {"phase": "Writing Output File", "fraction": 1}),
    "renderChat": ("running", {"phase": "Rendering Video", "fraction": 0.62,
                               "remaining": 38, "index": 2, "total": 2}),
    "downloadVideo": ("running", {"phase": "Downloading", "fraction": 0.35,
                                  "index": 2, "total": 4}),
    "composite": ("queued", None),
    "assemble": ("queued", None),
}


def duration(seconds):
    """Swift's `Duration` Codable form: a 128-bit attosecond count as [high, low].

    Verified against the real encoder: 38s -> [2, 1106511852580896768].
    """
    atto = int(seconds * 10**18)
    high = atto >> 64
    low = atto & 0xFFFFFFFFFFFFFFFF
    if low >= 2**63:
        low -= 2**64
    return [high, low]


def stable_uuid(*parts):
    """Deterministic, so regenerating produces no diff when nothing changed."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "oxbow-fixture/" + "/".join(map(str, parts)))).upper()


def scrub(node, job_index, counter):
    """Walk the tree replacing identifying values, leaving structure alone."""
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            if key == "videoID":
                out[key] = f"20000000{job_index:02d}"
            elif key == "clipSlug":
                out[key] = f"FictionalClipSlug{job_index:02d}"
            elif key in ("destination", "artifact") and isinstance(value, str):
                name = Path(value).name
                out[key] = f"file:///Users/oxbow/Downloads/{name}"
            elif key == "rawValue" and isinstance(value, str) and "-" in value:
                counter[0] += 1
                out[key] = stable_uuid(job_index, counter[0])
            else:
                out[key] = scrub(value, job_index, counter)
        return out
    if isinstance(node, list):
        return [scrub(v, job_index, counter) for v in node]
    return node


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SOURCE
    if not source.is_file():
        sys.exit(f"no queue.json at {source}\n"
                 f"run Oxbow once, then pass the path to its queue.json")

    data = json.loads(source.read_text())
    available = data["jobs"]
    if not available:
        sys.exit(f"{source} has no jobs to build a fixture from")

    # Cycled rather than truncated: TITLES decides how many rows the
    # screenshot shows. Reusing a source job reuses only its *shape* — every
    # identifying field is replaced below, and ids derive from the row index,
    # so duplicated shapes still get distinct ones.
    #
    # VOD-shaped sources only: a clip job carries `downloadClip`, which
    # RUNNING_PLAN has no entry for, so the mid-flight row would silently keep
    # whatever status the source happened to have.
    shaped = [j for j in available
              if any("downloadVideo" in s["kind"] for s in j["steps"])] or available
    jobs = [shaped[i % len(shaped)] for i in range(len(TITLES))]

    # Deterministic ids have to be assigned before dependsOn is rewritten, or
    # the two sides of an edge get different values and every step looks
    # blocked. Scrubbing the whole job in one walk with a shared counter keeps
    # them consistent: dependsOn entries are visited in the same order the ids
    # were, because Codable wrote them that way.
    rebuilt = []
    for index, job in enumerate(jobs):
        original_ids = []

        def collect(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k == "rawValue" and isinstance(v, str):
                        original_ids.append(v)
                    else:
                        collect(v)
            elif isinstance(node, list):
                for v in node:
                    collect(v)

        collect(job)
        mapping = {old: stable_uuid(index, n) for n, old in enumerate(dict.fromkeys(original_ids))}

        def remap(node):
            if isinstance(node, dict):
                out = {}
                for key, value in node.items():
                    if key == "videoID":
                        out[key] = f"20000000{index:02d}"
                    elif key == "clipSlug":
                        out[key] = f"FictionalClipSlug{index:02d}"
                    elif key in ("destination", "artifact") and isinstance(value, str):
                        out[key] = f"file:///Users/oxbow/Downloads/{Path(value).name}"
                    elif key == "rawValue" and isinstance(value, str):
                        out[key] = mapping.get(value, value)
                    else:
                        out[key] = remap(value)
                return out
            if isinstance(node, list):
                return [remap(v) for v in node]
            return node

        job = remap(job)
        job["title"] = TITLES[index]
        # The window draws `controller.jobs` in array order with no sort, so
        # `created` does not decide position — TITLES does. It is set
        # ascending anyway so the running row at the bottom is also the most
        # recently added, which is the only reading under which the rows above
        # it are already finished.
        job["created"] = 810_000_000.0 + index * 86_400.0

        if index == RUNNING_JOB:
            for step in job["steps"]:
                kind = next(iter(step["kind"]))
                plan = RUNNING_PLAN.get(kind)
                if plan is None:
                    continue
                status, progress = plan
                step["status"] = {status: {}}
                if progress is None:
                    # `Step.progress` is non-optional (`var progress:
                    # StepProgress`), so a queued step still needs the key —
                    # an empty object decodes to a StepProgress with every
                    # field nil. Omitting it makes the whole file fail to
                    # decode, and QueueStore's recovery is to move it to
                    # queue.json.bak and start empty, so the symptom is a
                    # blank window rather than an error. `artifact` is `URL?`
                    # and may genuinely be absent.
                    step["progress"] = {}
                    step.pop("artifact", None)
                else:
                    encoded = dict(progress)
                    if "remaining" in encoded:
                        encoded["remaining"] = duration(encoded["remaining"])
                    step["progress"] = encoded

        rebuilt.append(job)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"version": data["version"], "jobs": rebuilt},
                              indent=2, sort_keys=True) + "\n")

    leaked = [line for line in OUT.read_text().splitlines() if os.path.expanduser("~") in line]
    if leaked:
        sys.exit(f"refusing to write: {len(leaked)} line(s) still contain your home path")

    # Which row scripts/screenshots.sh should open. Written here rather than
    # hardcoded there because it has to name the mid-flight job exactly, and
    # two places holding that independently is two places to forget.
    (OUT.parent / "expand.txt").write_text(TITLES[RUNNING_JOB] + "\n")
    (OUT.parent / "videoinfo.json").write_text(json.dumps(INTAKE, indent=2) + "\n")
    (OUT.parent / "link.txt").write_text(INTAKE_LINK + "\n")

    print(f"wrote {OUT.relative_to(Path.cwd()) if OUT.is_relative_to(Path.cwd()) else OUT}")
    print(f"  {len(rebuilt)} jobs, job {RUNNING_JOB} caught mid-flight")
    print(f"  intake: {INTAKE['streamer']} - {INTAKE['title']}")


if __name__ == "__main__":
    main()
