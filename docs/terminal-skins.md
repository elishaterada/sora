# Terminal skins

Open **Settings → Skins → Add Photo or Video…** to use a local image or movie
behind the terminal. Sora copies each import into its own library and selects
it immediately. Moving or deleting the source file does not remove the skin.
Local imports, playback, and rotation work with Agent disabled.

Supported files include JPEG, PNG, HEIC, MP4, and MOV, subject to macOS decoding
support. Imports must be nonempty regular files no larger than 2 GB. Invalid
images and unplayable videos report an error instead of entering the catalog;
H.264 MP4 is a useful export format for incompatible videos. Removing a skin
requires confirmation and deletes Sora's copy, leaving the source untouched.

## Appearance and playback

- **Readability** adjusts a theme-adaptive tint from 25% to 95%, initially 65%,
  over native glass and the media. Increase it for a calmer text backdrop.
- **Extend photos with softened edges** preserves the whole photo and fills
  spare space with a blurred enlargement of its colors. Turning it off fills
  the available area by cropping. This is local image presentation, not
  generated outpainting or reconstruction of the scene.
- **Subtle perspective with pointer movement** adds a small pointer-driven
  shift. It starts off.
- Videos loop and start muted. **Play this video's sound** is saved separately
  for each video with an audio track. Sound plays only in the active terminal
  window; the Settings preview is always muted. Playback pauses while the app
  is inactive or the window is not visible.
- **Change skin** cycles through library order every minute, 5, 15, or 30
  minutes, hour, or day. Manual selection is the default. Rotation runs while
  Sora is open, and all terminal windows share the selected skin.

macOS **Reduce Motion** pauses video and pointer movement, showing the video
poster. **Reduce Transparency** hides the media and glass behind a solid
background. These preferences update live. Arbitrary photos and videos can
still compete with text; readability is user-adjusted rather than a guarantee
of contrast for every frame.

## Prepare a clip with Agent

In **Make a clip with Agent**, enter a complete HTTPS video link and start/end
times in seconds. The start must be nonnegative, the end later than the start,
and the selected duration no more than 300 seconds. **Prepare with Agent…**
opens an editable draft in the existing app-owned clip Agent session. Send it
when ready; **Open Clip Agent** returns to its conversation and pending actions.
Agent must be enabled, and an unfinished task or existing draft must be completed
before preparing another clip.

The workflow asks Agent to inspect available tools, download into a unique work
folder, make an accurate cut, verify playable video and duration, and propose
the native **Add terminal skin** action. Downloads, installations, webpage
fetches, and file changes require approval in this session even when the global
mode is Full access. Routine read-only commands can run automatically only as
allowed by the effective permission mode. Native skin import always requires
explicit approval, including in Full access and when a prior grant exists.

`yt-dlp`, `ffmpeg`, and `ffprobe` are optional user-installed command-line tools,
not bundled dependencies. Agent can propose installation with approval. Its
instructions preserve optional audio, prefer H.264/AAC output, and verify cuts
rather than assuming stream-copy boundaries are accurate. Tool guidance follows
the [yt-dlp documentation](https://github.com/yt-dlp/yt-dlp) and
[FAQ](https://github.com/yt-dlp/yt-dlp-wiki/blob/master/FAQ.md); no downloader or
encoder implementation is copied into Sora. Downloads remain subject to source
availability and tool support.

## Ownership and failure handling

`SkinLibrary` owns one shared catalog under
`~/Library/Application Support/<bundle identifier>/Skins/`. Each skin has a UUID
folder containing the retained `original.<extension>` and a generated
`poster.jpg`; `library.json` records selection, appearance, audio, and rotation.
Import copies and decodes media off the main actor, stages the complete folder,
and publishes the catalog atomically. Failed saves do not publish the new
configuration. An unreadable or malformed catalog exposes an error and blocks
overwriting it. Settings offers **Show Skin Library in Finder** for inspection.

`SkinBackgroundView` owns AVFoundation playback, native glass, and local pointer
tracking independently of SwiftUI and Ghostty's terminal/PTY lifecycle. The
provider-independent `importSkin` tool resolves the approved target again and
calls the same native importer. Its result records actual import success or
failure for Agent's follow-up; shell commands must not edit the catalog.

## Verification and limits (2026-09-12)

The native importer was exercised with a real photo and an audio-bearing video:
retained originals survived relaunch, and new video imports remained muted.
The preview showed moving video; terminal `printf` output, photo selection,
ordered rotation, and saved sound toggles were exercised. A photo import also
completed through the native file picker. Dark and light terminal text were
checked over the supplied media. The readability slider was adjusted from
65% to 70% through its accessibility action; an invalid 301-second clip showed
the inline limit explanation. The independent finish review scored its three
requested fixes resolved. Local `ffmpeg`
trimming requested 2.25 seconds and produced a playable 2.266016-second H.264/AAC
clip within frame tolerance, which the native importer accepted. Sample media
is excluded from source control.

Automated coverage includes retained-source independence, persistence failure,
malformed catalogs, corrupt media, rotation and clip-input validation, mandatory
native-import approval, and AskSession integration. The final
`xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination
'platform=macOS' -parallel-testing-enabled NO build test` run passed all 377
tests (`/tmp/sora-skins-build.log`). External video downloads and a
real provider-driven clip conversation have not been verified. Audio balance,
motion comfort, and contrast across arbitrary media still need human review.

## Release 0.4.0 preflight

The exact 0.4.0 project version passed all 377 tests with the full build/test
command above (`/tmp/sora-0.4.0-tests.log`).
`MARKETING_VERSION=0.4.0 CURRENT_PROJECT_VERSION=21 ./Scripts/package-app.sh`
produced the Apple Silicon Release archive. The packaged app reports 0.4.0 / 21;
`lipo -archs` reports arm64, and `codesign --verify --deep --strict` passes.
The 0.4.0 changelog extraction contains the user-facing skin, rotation, readability,
audio and Agent clip highlights. Manual feature coverage is recorded above.
Distribution remains ad-hoc signed and not notarized, following `docs/releasing.md`.
