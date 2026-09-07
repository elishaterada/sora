# Changelog

Human-readable highlights for each Sora release live here. Add the newest
version before creating its `vX.Y.Z` tag; the release workflow requires a
matching section and publishes it to GitHub.

## 0.1.4 — 2026-09-06

### What’s new

- Links shown in the terminal now open in your default browser or application.
- Agent answers render Markdown progressively while they stream, including
  headings, lists, code, links, and local file paths.
- Streaming Agent conversations follow new content with smoother motion and
  respect the macOS Reduce Motion setting.
- The README now explains installation, privacy, providers, permissions, and
  the project’s current preview status for public readers.

### Fixes

- Reduced the visual jump when a streaming Agent response finishes and changes
  from plain text to formatted Markdown.

## 0.1.3 — 2026-09-06

### What’s new

- Sora can check GitHub once at launch for a newer version, then download,
  verify, install, and relaunch the app through Sparkle.
- Updates and the update feed are protected with EdDSA signatures.

## 0.1.2 — 2026-09-06

### What’s new

- Command groups have durable separators that move with terminal content when
  it scrolls or reflows.
- A separator appears before the next command is typed, with balanced space on
  both sides and no extra space above the first command.

### Fixes

- Clearing the terminal now removes command separators along with the content.
- Resizing the terminal no longer leaves separators detached from reflowed
  command output.

## 0.1.1 — 2026-09-06

### What’s new

- Command duration and the visual boundary between commands are now presented
  separately, making completed command groups easier to scan.

## 0.1.0 — 2026-09-05

### What’s new

- First installable preview of Sora for Apple Silicon Macs.
- Added the release packaging workflow and downloadable application archive.
