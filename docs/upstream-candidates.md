# Upstream candidates

Defects in `TwitchDownloaderCLI` found while building Oxbow, written up so they
can be taken upstream without re-deriving the evidence. Etiquette and audience:
`docs/architecture.md` §8. Measurements are against the vendored submodule at
`d4122d8` (upstream 1.56.5) unless stated.

**This file is not a claim that upstream is slow or unresponsive.**
`docs/design/cli-dependency.md` §2 measured that project's rhythm: bursts
separated by months. Candidates sit here until somebody takes them.

| # | Candidate | State |
|---|---|---|
| — | Interactive prompts hang on redirected stdin | submitted, [PR #1644](https://github.com/lay295/TwitchDownloader/pull/1644) |
| — | `chatdownload` on a clip whose parent VOD is gone dies on SIGABRT | submitted, [PR #1646](https://github.com/lay295/TwitchDownloader/pull/1646) |
| 1 | **Default username colours change on every render** | written up below |
| 2 | `chatdownload -E` decodes animated frames it discards | sketch, `docs/design/native-chat-render.md` §9.1 |

---

## 1. Default username colours change on every render

**One line:** a viewer who has never set a Twitch colour is drawn in a
different colour every time the same chat is rendered, because the colour is
chosen by a hash that .NET randomises per process.

### Symptom

Render the same chat JSON twice, with identical arguments, and the two videos
differ. Not subtly — in the reference measurement below, **5,322 of 5,400
frames** differ, because most frames contain at least one such viewer.

For a downstream consumer this means a chat render is not reproducible: a job
retried, resumed, or re-rendered at a different size produces a differently
coloured chat, and a user who re-renders to fix an unrelated setting finds
their regulars have changed colour.

### Mechanism

`TwitchDownloaderCore/ChatRenderer.cs:1739`:

```csharp
var userColor = colorOverride ?? (comment.message.user_color is not null
    ? SKColor.Parse(comment.message.user_color)
    : DefaultUsernameColors[Math.Abs(comment.commenter.display_name.GetHashCode()) % DefaultUsernameColors.Length]);
```

`string.GetHashCode()` on .NET Core is **randomised per process** — by design,
as hash-flooding mitigation, and not disableable the way .NET Framework's
`UseRandomizedStringHashAlgorithm` was. So the index into
`DefaultUsernameColors` is stable *within* a render and arbitrary *between*
renders. The intent is plainly one stable colour per viewer; the palette and
the modulo say so.

The same pattern appears a second time for default avatars,
`ChatRenderer.cs:1867`:

```csharp
avatarUrl = DefaultAvatarUrls[Math.Abs(comment.commenter.display_name.GetHashCode()) % DefaultAvatarUrls.Length];
```

so `--avatars` gives a viewer a different default avatar per render too. One
fix should cover both call sites.

**Secondary, latent:** `Math.Abs(int.MinValue)` throws `OverflowException`. A
`display_name` whose hash lands on `int.MinValue` crashes the render. With a
randomised seed that is a fresh ~1-in-4-billion draw per distinct name per
process, so it is a curiosity rather than a bug anyone has hit — but any fix
that returns a non-negative hash removes it for free.

### Evidence, measured 2026-09-17

VOD `2856361990` (7:37:20, Just Chatting, ~418 messages/minute), the window at
2:30:00 for 180 seconds: 1,250 comments, of which **170 have
`message.user_color: null`**.

Rendered twice from one saved JSON, at Oxbow's geometry (342x1026 @ 30fps,
font size 15, `--dispersion`), written **losslessly** (`-c:v ffv1 -pix_fmt
bgra`) so the encoder cannot be blamed, and compared by decoded-frame hash:

| Comparison | Frames differing of 5,400 |
|---|---|
| same JSON, rendered twice | **5,322** (mean RGB MSE 67.6) |
| same, after replacing every `null` `user_color` with a fixed value | **0** |

The second row is what identifies the cause: with colours pinned in the input,
the renderer is exact — layout, wrapping, emotes, dispersion and timing all
reproduce frame for frame. A side-by-side of frame 3000 from the two runs shows
identical text and emotes with several usernames in different colours.

Reproduction, including the colour-pinning script: `docs/design/native-chat-render.md` §12.

### Suggested fix

Replace the randomised hash with a deterministic one over the same input,
keeping the existing palette so renders stay recognisable. A small private
helper — FNV-1a over the UTF-16 code units, or any fixed non-cryptographic
hash — used by both call sites, returning a non-negative value so `Math.Abs`
disappears.

Deliberately **not** proposed here:

- **Keying off `commenter._id` instead of `display_name`.** More stable in
  principle, since a rename would keep the colour. But it changes which colour
  every uncoloured viewer gets, and whether Twitch's own default colour derives
  from the user id is not something this write-up has verified. If upstream
  prefers it, that is their call to make, not a thing to smuggle into a bugfix.
- **Matching Twitch's web client's default colour exactly.** Unverified, and a
  much larger claim.

Colours for uncoloured viewers *will* change once, compared to whatever the
current build happened to produce for a given process. That is unavoidable, and
is the point: today there is nothing to preserve, because there is no stable
value to begin with.

### How a reviewer can check it

1. Download any chat with uncoloured viewers (most heavy-chat VODs).
2. Render it twice with identical arguments to lossless output.
3. Compare decoded frames — `ffmpeg -i a.mkv -f framemd5 -` on each, then diff.

Before: nearly every frame differs. After: byte-identical decoded frames. A
unit test over the helper — same name, same index, across processes — is the
cheap regression guard.

### Why it matters beyond us

Anything that renders the same chat twice hits this: the WPF GUI shares
`ChatRenderer`, so a user re-rendering at a different size sees the colours
shuffle. It also makes upstream's own output untestable frame-for-frame, which
is a precondition for any future render regression test.
