# README media

The README leads with a linked video poster, following Luna’s README pattern. This provides a visible hero and a direct MP4 link without relying on a raw HTML video element surviving GitHub’s Markdown rendering. Playback opens from the link; the README does not autoplay the video.

## Assets

All media is 2280 × 1480 native pixels, captured September 14, 2026 from Sora 0.4.3/build 24. Files live in `docs/images/desktop/`.

- `06-video-poster.webp`: matching frame extracted at 7 seconds from the delivered MP4.
- `05-terminal-agent-return.mp4`: 17.991667 seconds, 1,035 frames, H.264, no audio, variable frame timing averaging 57.5266 fps. The reported 120 fps base rate is not a constant capture rate.
- `02-command-block.webp`: selected output with command-reuse controls.
- `03-context-review.webp`: expanded fictional output attachment before sending to Agent.

The video reopens a real answer generated during staging, returns to the same terminal, selects a command block, and recalls it for editing. It ends before execution. It is not an AI response-speed demo or an autonomous repair demonstration. All screenshots and the poster are lossless WebP.

## Provenance and verification

Media was copied unchanged from the completed Sora portfolio handoff. It uses the public 0.4.3 executable in an isolated demo profile and the fictional Starlight workspace. Local re-signing changed signature bytes; disposable unsigned copies matched the public executable byte-for-byte. No product UI or answer was fabricated. One actual OpenAI request answered a question about deliberately reviewed fictional CSV output; no credential appears in the assets.

Native desktop-region capture at x=186, y=138, width=1140, height=740 logical points on a 2× display preserves the actual wallpaper and window shadow. The 980 × 620-point window has 80-point horizontal and 60-point vertical desktop padding. Wallpaper, position, crop, and dark appearance remain consistent. No upscaling, artificial translucency, frame interpolation, or timing changes were applied; only the source recording’s first four seconds were trimmed.

The native purple capture indicator and pointer remain visible. Command selection intentionally uses a solid highlight. Window materials vary with macOS version and accessibility settings. The crop excludes unrelated apps, notifications, desktop icons, and recording controls.

All stills, the poster, and all 1,035 video frames were reviewed during handoff. The poster was checked against the final MP4, and retained frame timestamps matched the native source. README copies are checked against those reviewed originals. Raw captures and temporary review files remain outside this repository.
