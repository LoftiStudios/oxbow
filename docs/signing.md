# Signing, notarization, and the bundle layout

**Status:** resolved. Spike run 2026-08-23, verified end to end against Apple's
notary service. `scripts/sign.sh` and `scripts/entitlements/` are the outcome.

This was the piece `docs/architecture.md` §9 called "the last genuinely unfamiliar
thing" and the reason the previous attempt stalled. It works. Everything after
it is ordinary app work.

---

## 1. What was proven

A bundle containing the real helper (CoreCLR, SkiaSharp, 17 native Mach-Os and
183 managed assemblies) plus our LGPL FFmpeg was signed inside-out, notarized,
stapled, packaged as a DMG, notarized and stapled again, then quarantined and
launched as a real download:

| Check | Result |
|---|---|
| `codesign --verify --deep --strict` | valid on disk, satisfies its Designated Requirement |
| Notarization (`.app` zip) | **Accepted**, first submission |
| Notarization (`.dmg`) | **Accepted** |
| `stapler validate` | worked, both artifacts |
| `spctl -a -t exec` on a quarantined copy | `accepted / source=Notarized Developer ID` |
| Quarantined app spawns helper + FFmpeg | both executed |
| GUI launch from quarantine | launched, no syspolicy denials |

Signing identity: `Developer ID Application: Barclay loftus (M9WJGEJKBF)`.
Notary credentials live in the keychain as the `oxbow-notary` profile; the
`.p8` itself is never on disk in the repo and never needs to be.

## 2. The rule that costs an afternoon

**Every file under `Contents/MacOS` must be signed, whatever its type.**

That directory is the bundle's code location, so `codesign` treats everything in
it as a code object. Not just Mach-O binaries — .NET managed assemblies (PE32+,
signed as `Format=generic`), `.runtimeconfig.json`, `.deps.json`, even
`COPYRIGHT.txt`. Miss one and bundle verification fails with:

```
code object is not signed at all
In subcomponent: .../Contents/MacOS/helper/COPYRIGHT.txt
```

Signing only the Mach-O files is the intuitive approach and it is wrong. For
this bundle that is **205 files**, not 19.

`scripts/sign.sh` therefore signs everything under `Contents/MacOS`, deepest
first, and re-checks each file individually afterwards rather than trusting
`--deep` verification alone.

## 3. Entitlements, determined empirically

`docs/architecture.md` §10 said to test rather than assume. Tested:

| Signature | Result |
|---|---|
| Helper with `com.apple.security.cs.allow-jit` | runs |
| Helper with **no** entitlements | `Failed to create CoreCLR, HRESULT: 0x80070008` |

So `allow-jit` is genuinely required — and it is also **sufficient**. Neither
`allow-unsigned-executable-memory` nor `disable-library-validation` was needed.
That is precisely the payoff for refusing `PublishSingleFile`: every Mach-O is
signed with one Team ID, so library validation is satisfied without weakening
it. If you ever find yourself reaching for `disable-library-validation`,
something is signed wrong — fix the signing, don't add the entitlement.

Entitlements are **per-process** and do not propagate from parent to child, so
the helper carries its own. Scoping:

- `Contents/MacOS/helper/*` native executables → `helper.entitlements` (allow-jit)
- `ffmpeg` → hardened runtime, **no entitlements** (it does not JIT)
- dylibs and managed assemblies → no entitlements; they are not process images
- the app bundle → `app.entitlements`, currently empty

## 4. Bundle layout

```
Oxbow.app/Contents/
  MacOS/
    Oxbow                    <- SwiftUI app
    ffmpeg                   <- our LGPL build, one Mach-O, no entitlements
    helper/                  <- .NET publish tree, 205 files
      TwitchDownloaderCLI    <- apphost, allow-jit
      createdump             <- ships with self-contained .NET, must be signed
      libSkiaSharp.dylib     <- universal (x86_64 + arm64)
      libHarfBuzzSharp.dylib <- universal
      lib*.dylib             <- CoreCLR runtime
      *.dll                  <- 183 managed assemblies
  Resources/
    ...                      <- NO executable code, ever
```

Native Mach-O count: 19 (17 helper + ffmpeg + app). Bundle ~147 MB, DMG ~77 MB.

## 5. Publishing the helper

Upstream's own `MacOSArm64.pubxml` sets `PublishSingleFile=True`,
`IncludeNativeLibrariesForSelfExtract=true` and `PublishTrimmed=True` — the
first two are exactly what handoff §3.3 forbids. **Never publish with
`-p:PublishProfile=MacOSArm64`.** Override explicitly:

```bash
dotnet publish vendor/TwitchDownloader/TwitchDownloaderCLI \
  -c Release -r osx-arm64 --self-contained true \
  -p:PublishSingleFile=false \
  -p:PublishTrimmed=false \
  -p:PublishReadyToRun=false \
  -p:DebugType=none \
  -o build/helper
```

`DebugType=none` keeps `.pdb` files out of the output. They are build artifacts
that would otherwise land under `Contents/MacOS` and have to be signed for no
benefit. `sign.sh` deletes any it finds as a backstop.

Trimming is off deliberately: the stack is reflection-heavy (SkiaSharp,
CommandLineParser, `System.Text.Json` with reflection re-enabled), and trimming
buys size at the cost of failures that only appear on specific code paths.

## 6. App Translocation

A quarantined app launched from outside `/Applications` runs from a randomized
**read-only** mount under `/private/var/folders/.../AppTranslocation/`. Verified:
the helpers are present there and execute fine, but the bundle cannot be written
to.

This independently validates the architecture in handoff §5 — the CLI must be
told to write into a temp directory or the app container, with the Swift parent
moving finished files to the user's chosen location. Anything that tried to
write next to the app would fail on first run for every user who launches from
`~/Downloads`.

## 7. Order of operations

```bash
./scripts/build-ffmpeg.sh                     # LGPL FFmpeg
dotnet publish ...                            # helper (see §5)
# assemble bundle
./scripts/sign.sh build/Oxbow.app             # inside-out, 205 files
ditto -c -k --keepParent build/Oxbow.app build/Oxbow.zip
xcrun notarytool submit build/Oxbow.zip --keychain-profile oxbow-notary --wait
xcrun stapler staple build/Oxbow.app
# build DMG from the stapled .app, then sign / notarize / staple the DMG too
```

Staple the `.app` **before** packaging it into the DMG, and staple the DMG as
well. Stapling is what makes first launch work without a network round trip.

`ditto -c -k --keepParent` matters: managed assemblies carry `Format=generic`
signatures stored in extended attributes, and a plain `zip` drops xattrs.

## 8. Open items

- **Xcode integration: resolved (2026-08-24).** `scripts/embed-helpers.sh`,
  run from an "Embed & Sign Helpers" Run Script phase on the app target,
  embeds `build/helper` and `build/ffmpeg/ffmpeg` into `Contents/MacOS` and
  signs them inside-out. The "Code Sign On Copy" trap is sidestepped entirely
  by not using a Copy Files phase at all — the script both copies and signs,
  so sign-after-embed is guaranteed, and Xcode's own signing of the bundle
  runs after all phases, preserving the inside-out order. Verified: 205 files
  signed, `--deep --strict` passes, the helper carries `allow-jit` and boots
  CoreCLR, FFmpeg executes. Dev builds sign with the Apple Development
  identity and no timestamp; distribution still goes through `sign.sh`.
- **`libSkiaSharp.dylib` and `libHarfBuzzSharp.dylib` ship universal** while v1
  is arm64-only. `lipo -thin arm64` would save roughly 8 MB, but it must happen
  *before* signing. Not done yet.
- **CI: partly resolved (2026-08-24).** `.github/workflows/full-build.yml`
  builds the whole bundle on pushes to main, nightly and on demand: submodule
  checked out, helper published, FFmpeg built (cached on a hash of
  `scripts/build-ffmpeg.sh`), and the app built with **ad-hoc** signing so
  `embed-helpers.sh` runs its real `codesign` calls with the real entitlements.
  It then asserts §2–§4 the way `sign.sh` does locally: helper and ffmpeg
  present under `Contents/MacOS`, ~205 embedded files, every file individually
  signed, `--deep --strict` clean, `allow-jit` on the helper's own signature
  and absent from ffmpeg's. What is still missing is **distribution** signing
  and notarization, which need the cert as a base64 `.p12` and the notary key
  as repository secrets — a separate release workflow.
