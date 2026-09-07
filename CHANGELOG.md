# Changelog

Human-readable highlights for each Sora release live here. Add the newest
version before creating its `vX.Y.Z` tag; the release workflow requires a
matching section and publishes it to GitHub.

## 0.1.5 — 2026-09-07

### What’s new

- Dictate editable text into the terminal prompt or Agent composer using the
  microphone, then review it before submitting.
- Have a live spoken conversation in Agent with supported OpenAI Realtime
  models, including streaming transcripts, spoken replies, and interruption.
- Configure Terminal, Agent providers, credentials, permissions, and Voice in
  a dedicated, expandable macOS Settings window while conversations stay
  focused on interacting with Agent.

- Edit commands in a distinct bottom input panel with multiline input,
  automatic wrapping, click-to-position, and drag-to-copy selection.
- Read command history more easily with darker output blocks and balanced
  spacing around separators.

### Fixes

- Shell aliases and functions take precedence over automatic Agent routing.
- Agent automatically retries malformed action requests.
- Empty Returns no longer add blank rows to command history.
- Input updates promptly while completion hints settle without flashing.
- Command spacing stays consistent when scrolling through older output.

### Safety and privacy

- Realtime voice stops when Agent is hidden and cannot execute terminal
  commands; terminal actions still go through the typed approval flow.

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
