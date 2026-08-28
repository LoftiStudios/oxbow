# Contributing to Oxbow

Oxbow is a native macOS front end for
[TwitchDownloader](https://github.com/lay295/TwitchDownloader). It drives a
bundled `TwitchDownloaderCLI` helper as a subprocess.

Contributions are welcome. The rules below are not style preferences — the ones
under [Hard rules](#hard-rules) produce builds that fail notarization or break
silently on other people's machines.

## Two ways to build

Most contributions do not need the full toolchain. Pick the lighter one if it
covers your change.

### Fast path — `OxbowKit` only

`OxbowKit` is the queue engine, the CLI argument builder, the output parser, and
the persistence layer. It is pure Swift with no dependency on .NET, FFmpeg, or
the submodule, and its tests are the bulk of the suite.

You need Xcode (or a Swift 6.2 toolchain) and nothing else:

```bash
git clone https://github.com/barclay/oxbow.git
cd oxbow
swift test
```

That is the whole loop. No submodule init, no .NET SDK, no FFmpeg build. If your
change lives under `Sources/OxbowKit`, stop here.

### Full path — the app bundle

Needed only if you are touching the app target, the helper integration, or the
build and signing scripts.

**Clone with submodules.** `vendor/TwitchDownloader` is pinned to an exact
commit, in a mirror of upstream we add nothing to; a plain clone leaves it empty
and the build fails confusingly.

```bash
git clone --recurse-submodules https://github.com/barclay/oxbow.git
```

Already cloned without it:

```bash
git submodule update --init --recursive
```

Then:

1. **.NET 10 SDK** — `brew install --cask dotnet-sdk`. Upstream targets .NET 10.
2. **FFmpeg** — `./scripts/build-ffmpeg.sh`. This compiles from source and takes
   a while. It is not optional and you cannot substitute a Homebrew or
   evermeet.cx binary; see [Hard rules](#hard-rules).
3. **Xcode**, for the app target.

The full command reference lives in [`docs/development.md`](docs/development.md).

### What you cannot do

**You cannot produce a distributable build.** Signing and notarization require a
Developer ID certificate tied to a specific paid Apple Developer account, and
that credential is personal and non-transferable. Releases are cut by the
maintainer only. This is a property of how Apple distributes software, not a
policy choice, and it will not change.

Your unsigned local build will be blocked by Gatekeeper on first launch. Right
click the app and choose Open, or clear the quarantine attribute:

```bash
xattr -dr com.apple.quarantine build/Oxbow.app
```

## Hard rules

Full rationale for each of these is in [`docs/development.md`](docs/development.md) and
[`docs/architecture.md`](docs/architecture.md). They were arrived at by hitting the
failure, not by guessing.

**`vendor/TwitchDownloader` is read only.** Do not patch it locally, ever. If
something upstream needs to change, say so in an issue and it goes upstream as
its own PR. We do not want to maintain a fork.

**Never `-p:PublishSingleFile=true`** when publishing the helper. It extracts
unsigned native libraries at runtime and forces `disable-library-validation`,
which is a signing smell we refuse to ship. Publish a directory; sign each file.

**Never add `--enable-gpl`, `--enable-nonfree`, or `--enable-version3`** to
`scripts/build-ffmpeg.sh`. Oxbow ships FFmpeg under LGPL 2.1+. Every
readily-available macOS FFmpeg binary is GPL because they all enable libx264,
which is exactly why we compile our own. A GPL FFmpeg in the bundle would make
Oxbow's MIT license a lie.

**Never `codesign --deep` for signing.** It applies one set of entitlements to
every nested binary, which is backwards when the helper needs its own. It is
fine for *verifying*.

**Do not bump the submodule pin as a side effect.** A gitlink is one exact SHA;
there are no version ranges. Bumping it is its own commit, whose message says
what changed upstream and why we want it.

## Pull requests

- **Conventional commits**, matching existing history:
  `feat(engine):`, `fix(persistence):`, `test(parsing):`. Scopes track the
  `Sources/OxbowKit` subdirectories — `model`, `parsing`, `scheduling`,
  `persistence`, `process`, `arguments`, `engine` — plus `build` for the
  scripts.
- **Tests come with the change.** `OxbowKit` is tested to a standard; new
  behaviour in it should arrive tested.
- **Keep PRs focused.** One concern per PR. A drive-by refactor in the same diff
  makes the real change harder to review.
- **Explain the why in the body.** The what is in the diff.

Architectural decisions and their rationale live in
[`docs/architecture.md`](docs/architecture.md). If you are about to propose something
listed there under "Do not suggest", read that section first — it was
considered and rejected for stated reasons, and a PR is not the place to
relitigate it. Open an issue instead.

## Scope

Oxbow is deliberately small. v1 is arm64 only and targets macOS 15+. Some things
are out of scope by design: cross-platform UI frameworks, Mac App Store
distribution, and reimplementing chat rendering in Swift. See "Do not suggest"
in [`docs/development.md`](docs/development.md).

## Reporting bugs

Use the issue templates. For anything involving a failed download or render,
include the app version, your macOS version, and your Mac's chip — those three
account for most of what we would otherwise have to ask for.

## License

By contributing you agree that your contributions are licensed under the MIT
License, the same terms that cover the rest of Oxbow.
