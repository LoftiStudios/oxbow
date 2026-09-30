"""Tests for symbolicate-crash.py, against the body CrashIssue actually writes.

    python3 -m unittest discover -s scripts -p 'test_*.py'
"""

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "symbolicate_crash", ROOT / "scripts" / "symbolicate-crash.py")
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

# Kept in step with CrashIssue by CrashIssueTests.matchesTheBodyTheSymbolicatorParses.
BODY = (ROOT / "Tests/OxbowKitTests/Fixtures/crash-issue-body.md").read_text()
UUID = "8C3A5A96-07E1-33FD-96E8-5DE188DD38B8"


class Parse(unittest.TestCase):

    def test_reads_version_uuid_and_frames(self):
        report = sc.parse(BODY)
        self.assertEqual(report["version"], "0.5.0")
        self.assertEqual(report["uuid"], UUID)
        self.assertEqual(report["frames"][0][1:], ("libdispatch.dylib", 227972))
        self.assertIn(("Oxbow", 50488), [f[1:] for f in report["frames"]])

    def test_ignores_an_issue_oxbow_did_not_write(self):
        self.assertIsNone(sc.parse("The app is slow when I open it."))

    def test_rejects_a_version_that_is_not_one(self):
        body = BODY.replace("Oxbow 0.5.0 (147)", "Oxbow 0.5.0;rm -rf (147)")
        self.assertIsNone(sc.parse(body)["version"])

    def test_keeps_the_omitted_frames_line(self):
        body = BODY.replace("```\n\nOxbow binary", "… 3 more frames\n```\n\nOxbow binary")
        self.assertEqual(sc.parse(body)["frames"][-1], ("… 3 more frames", None, None))

    def test_reads_three_digit_frame_numbers(self):
        body = BODY.replace("15 libsystem_pthread.dylib     + 7392",
                            "100 Oxbow  + 12")
        self.assertIn(("Oxbow", 12), [f[1:] for f in sc.parse(body)["frames"]])


    def test_reads_frame_numbers_run_into_the_name(self):
        # How 0.6.0 writes frame 100 onwards.
        body = BODY.replace("15 libsystem_pthread.dylib     + 7392", "100Oxbow  + 12")
        self.assertIn(("Oxbow", 12), [f[1:] for f in sc.parse(body)["frames"]])
        comment = sc.comment_for(body, lambda v: "/d", lambda d, u, o: {12: "f()", 50488: "g()"})
        self.assertIn("100 Oxbow", comment)


class Comment(unittest.TestCase):

    def test_names_oxbows_frames_and_leaves_the_rest(self):
        asked = []

        def symbolicate(dwarf, uuid, offsets):
            asked.append((dwarf, uuid, offsets))
            return {50488: "CrashReporter.didReceive(_:) (CrashReporter.swift:21)"}

        comment = sc.comment_for(BODY, lambda v: f"/dsym/{v}", symbolicate)
        self.assertEqual(asked, [("/dsym/0.5.0", UUID, [50488])])
        self.assertIn(sc.COMMENT_MARKER, comment)
        self.assertIn("5  Oxbow                       CrashReporter.didReceive(_:) (CrashReporter.swift:21)", comment)
        self.assertIn("0  libdispatch.dylib           + 227972", comment)
        self.assertNotIn("+ 50488", comment)

    def test_says_so_when_the_release_has_no_dsym(self):
        comment = sc.comment_for(BODY, lambda v: None, lambda *a: self.fail())
        self.assertIn("no dSYM is attached to the v0.5.0 release", comment)

    def test_says_so_when_the_dsym_is_another_build(self):
        comment = sc.comment_for(BODY, lambda v: "/dsym", lambda *a: None)
        self.assertIn("does not match", comment)

    def test_says_so_for_a_development_build(self):
        body = BODY.replace(f"Oxbow binary: `{UUID}`", "")
        comment = sc.comment_for(body, lambda v: self.fail(), lambda *a: self.fail())
        self.assertIn("development build", comment)

    def test_posts_nothing_for_an_ordinary_issue(self):
        self.assertIsNone(sc.comment_for("Feature request", lambda v: None, lambda *a: {}))


if __name__ == "__main__":
    unittest.main()
