# Security Policy

## Supported versions

Oxbow is pre-alpha and has not had a release yet. Once releases begin, only the
latest one is supported.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it through GitHub's private vulnerability reporting: go to the
[Security tab](https://github.com/loftiStudios/oxbow/security/advisories/new)
and open a draft advisory. That channel is private between you and the
maintainer.

You should get an acknowledgement within a few days. Oxbow is maintained by one
person in their spare time, so please allow reasonable time for a fix before
disclosing publicly.

## What is in scope

Oxbow is a signed, notarized macOS app that spawns two bundled subprocesses —
`TwitchDownloaderCLI` and `ffmpeg` — and passes them user-supplied input. The
interesting surface is therefore:

- **Argument injection** into either subprocess from user-controlled values
  (URLs, VOD IDs, filenames, output paths).
- **Path traversal** in the workspace or in the move of finished artifacts to
  the user's chosen destination.
- **Anything that lets Oxbow execute code that is not part of the signed
  bundle.** Oxbow's whole security posture is that everything it runs was signed
  under the maintainer's Developer ID and notarized by Apple. A path that
  defeats that is the most serious class of bug here.
- **Entitlement or signing weaknesses** in the app or its helper.

## What is not in scope

- **Vulnerabilities in TwitchDownloader itself.** Report those to
  [upstream](https://github.com/lay295/TwitchDownloader). If the bug is in how
  *Oxbow drives* the CLI, it belongs here.
- **Vulnerabilities in FFmpeg.** Report those to the
  [FFmpeg project](https://ffmpeg.org/security.html). If our build configuration
  is what exposes an issue, that is in scope here.
- Anything requiring an attacker to already have code execution or admin rights
  on the user's Mac.
