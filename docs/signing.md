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

Signing identity at the time of the spike: `Developer ID Application: Barclay
loftus (M9WJGEJKBF)`, a personal account. Releases move to the Lofti Studios LLC
organization account; see §9. Notary credentials live in the keychain as the
`oxbow-notary` profile; the `.p8` itself is never on disk in the repo and never
needs to be.

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
  and absent from ffmpeg's.
- **Release: resolved (2026-08-25).** `.github/workflows/release.yml` runs that
  same build with the real Developer ID identity, then notarizes and staples
  the app AND the DMG — the image's ticket is gone the moment the user drags
  the app out of it, so the app needs its own. The certificate arrives as a
  base64 `.p12` secret and is imported into a throwaway keychain deleted in an
  `always()` step; notarization uses an App Store Connect API key rather than a
  keychain profile, which CI cannot have. Two gates run before anything
  expensive: the tag must match `MARKETING_VERSION`, and the submodule must be
  pinned to an upstream release tag.

---

## 9. Moving from the personal account to Lofti Studios LLC

Releases were signed by a personal Developer ID (team `M9WJGEJKBF`). They move
to the organization account, team `Z4PBYBS53X`. Nothing in the repo hardcodes the identity:
`release.yml` takes the certificate and notary key from secrets and the team
from the `DEVELOPMENT_TEAM` repository variable, and `sign.sh` picks the sole
`Developer ID Application` identity in the keychain. The migration is
therefore credentials, not code.

### What changes for installed users

Updates are a manual DMG download (there is no Sparkle), so there is no
update-signature continuity to break, and the bundle ID `studio.lofti.Oxbow` is
unchanged. Gatekeeper accepts a notarized build from any team.

The one visible effect: macOS keys privacy grants to the designated
requirement, which includes the Team ID, so it treats the new build as a
different app. Users may be asked again for folder access (Downloads,
Documents, Desktop, removable volumes), and possibly for notification
permission. It happens once. Say so in the release notes.

### Runbook

1. **Certificate.** As Account Holder, create a `Developer ID Application`
   certificate under the Lofti Studios team (Certificates, Identifiers &
   Profiles). Generate the CSR on the machine that will keep the key.
2. **Export.** Export the certificate with its private key as a `.p12` from
   Keychain Access, with a new password.
3. **Notary key.** Create a new App Store Connect API key in the Lofti Studios
   account (Users and Access, Integrations). The old key belongs to the
   personal team and cannot notarize for the new one. Store the `.p8` once;
   Apple will not show it again.
4. **Local notary profile**, replacing the old one:

   ```bash
   xcrun notarytool store-credentials oxbow-notary \
     --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

5. **Repository secrets and variable** (Settings, Secrets and variables,
   Actions): replace `DEVELOPER_ID_P12_BASE64` (`base64 -i cert.p12 | pbcopy`),
   `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_PRIVATE_KEY`, `NOTARY_KEY_ID`,
   `NOTARY_ISSUER_ID`, and set the variable `DEVELOPMENT_TEAM` to the new
   Team ID. Update the local, gitignored `Config/Local.xcconfig` too.
6. **Verify before releasing.** Sign a build with the new identity and
   confirm the Team ID and the notarized verdict. The identity is
   `Developer ID Application: Lofti Studios, LLC (Z4PBYBS53X)`, with a comma;
   `IDENTITY` must match it exactly. Done 2026-09-30: Accepted, and `spctl`
   reports `source=Notarized Developer ID`.

   ```bash
   codesign -dv --verbose=2 build/Oxbow.app 2>&1 | grep -E 'Authority|TeamIdentifier'
   spctl -a -t exec -vv build/Oxbow.app   # source=Notarized Developer ID
   ```

7. **Ship it in an ordinary release**, not a special one, with the permission
   note in the changelog.
8. **Afterwards**, revoke nothing yet. Keep the personal certificate until the
   first release under the new team has been installed successfully, then
   delete the old CI secrets' values by overwriting them.

### Rollback

Signing is per release. If the first Lofti-signed build misbehaves, re-run the
release with the old secrets restored; users on the new build would then see
one more permission re-prompt in the other direction.
