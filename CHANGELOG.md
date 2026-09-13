# Changelog

Human-readable highlights for each Sora release live here. Add the newest
version before creating its `vX.Y.Z` tag; the release workflow requires a
matching section and publishes it to GitHub.

## 0.4.2 — 2026-09-13

### What’s new

- A new moonlit icon brings a larger full-body cat to the Dock, with indigo and lavender colors and proportions that match Luna.

## 0.4.1 — 2026-09-12

### Fixes

- Select and copy individual words or passages in Agent responses, including answers containing web links and file paths. Selection can span paragraphs while links remain clickable.
- Keep selected response text highlighted when unrelated parts of the conversation update.

## 0.4.0 — 2026-09-12

### What’s new

- Make your terminal your own with photo and video backgrounds in Settings → Skins. Sora keeps its own copy, so your favorites stay available even after you move or delete the original file.
- Switch between saved skins or rotate them automatically, from every minute to every day. All terminal windows share your selection.
- Blend your background with native glass and adjust the readability slider to keep text comfortable. Preserve the whole photo with softened edges, or add subtle pointer-driven perspective.
- Enjoy looping video backgrounds with optional sound for each video. New videos start muted, and sound plays only in the active terminal window.
- Prepare a video clip with Agent by entering a link and the seconds to keep. Review download and file-change approvals, then let Agent add the finished clip directly to your skins.

### Notes

- Local skins work with AI disabled. Reduce Motion pauses video and perspective; Reduce Transparency restores a solid backdrop.
- Agent clip preparation requires an enabled provider and may need optional tools such as yt-dlp and ffmpeg. Clips can be up to five minutes; online sources depend on availability and tool support.

## 0.3.0 — 2026-09-12

### What’s new

- Make typing your own with ten mechanical-keyboard-inspired sounds, from soft taps and deep thocks to crisp clacks and springy clicks. Preview each sound, adjust its volume, and enjoy a deeper sound on Return.
- Add optional ambient glow, a Return-key light pulse, and eight varied typing-impact patterns. Adjust impact strength from 25% to 200%, preview the stronger Return hit, or turn all effects off with one button.

### Fixes

- Bring glass translucency back across the terminal, input area, and sticky command headers in both light and dark themes, while keeping command blocks and errors easy to distinguish.
- Soften ANSI background colors so they blend with the glass. Text selection and inverse-video highlights stay clear and solid.
- Keep typing impacts in place with springy rotation and recoil, without shifting the window across your desktop.

### Notes

- Playful effects are off by default and available in Settings → Terminal → Playful effects. Reduce Motion disables animated effects; Reduce Transparency keeps a solid window backdrop.
- Typing impacts animate the app’s content; the native macOS window border and shadow stay stationary.

## 0.2.0 — 2026-09-12

### What’s new

- Give Agent a goal and let it check results, recover from failures, and try another approach. Clear progress, limits, and permission requests help you stay in control.
- Keep Agent conversations and progress when switching tabs or restarting Sora. Restored tasks wait for you to resume them.
- Find commands with Control-R, search actions and sessions with Command-Shift-P, and save reusable commands for later editing.
- Search a selected command block, show only matching output lines, and bookmark useful output so it remains available after closing the original tab.
- Ask Agent about selected terminal output with an editable preview before sending.
- Arrange up to eight terminal panes, save named project layouts, and rename or reorder tabs. Light and dark themes, fonts, compact spacing, and configurable app shortcuts make the workspace easier to tailor.
- Receive alerts when background commands finish and click back to their tabs. Enable the optional Control-Option-S shortcut to show or hide Sora from another app, Space, or display.
- Use richer command and file suggestions, including accepting one word at a time with Option-Right.
- Set up optional Bash integration and export shell scripts for richer Bash/zsh behavior over SSH. Remote context stays distinct from local folders and Agent actions.

### Fixes

- Preserve tabs, split layouts, saved output, and unfinished local zsh input through app updates, quitting, and reopening. Workspace backups and protection against stale app copies reduce the risk of losing your session.
- Keep your place while reading Agent replies, with a visible way to jump to new output.
- Keep ordinary Bash and unintegrated shell prompts visible, and clear obsolete notification errors after permission is allowed.

### Notes

- Agent actions remain bounded; commands that change files or system state require approval. A restored conversation does not restart commands automatically.
- SSH sessions reopen as local shells with their saved output. Automatic reconnection, remote command recall, and Bash draft restoration are not included.

## 0.1.17 — 2026-09-11

### Fixes

- Browse each tab’s own command history with Up and Down. Commands from other tabs no longer appear in the picker, even when both tabs use the same folder.
- Keep a tab’s history when reopening it or restoring your workspace after restarting Sora. New tabs start with an empty history picker.

### History notes

- Commands recorded before this update remain available in the global History window. Completion suggestions still use shared history.

## 0.1.16 — 2026-09-11

### Fixes

- Start typing immediately after opening a terminal without leaving stray characters above the prompt. Early typing and pasted text are preserved until the shell is ready.
- Use Control-C to cancel a stalled shell startup and discard any queued draft.

### Known limitations

- Startup scripts that use zsh’s interactive `read` before the first prompt need to be cancelled with Control-C before typing can continue.

## 0.1.15 — 2026-09-11

### What’s new

- New terminal sessions show a welcome panel with useful shortcuts and a “Don’t show again” option.
- Multiline input grows up to half the terminal height, with scrolling for longer drafts.

### Fixes

- Keep long pasted commands visible before running them, including multiline export statements.
- Use Command-A to select current input, then copy, cut, delete, or replace it by typing or pasting.
- Select partial text with the mouse in terminal input, command output, and the Agent composer without dragging the window.

## 0.1.14 — 2026-09-11

### What’s new

- Spot failed commands more easily: command blocks with a nonzero exit status now have a subtle red background, including their pinned headers while scrolling.

### Fixes

- Preserve shell syntax colors in pinned command headers and keep their backgrounds opaque as output scrolls underneath.
- Keep failed block highlights when resizing the terminal or restoring saved scrollback.

## 0.1.13 — 2026-09-10

### What’s new

- Drop images into Agent to attach visual references, preview them, and remove them before sending. Image contents travel with the conversation, so the selected service does not need access to your local files.
- Drop an image into a running image-aware CLI such as Codex to paste the actual image through the macOS clipboard. At a shell prompt, dropping images inserts safely quoted file paths.
- Browse command history with Up and Down in the input. Click an output block to move between blocks with the arrow keys and access block actions.
- Keep the command visible while scrolling through long output with smoothly transitioning sticky headers.

### Fixes

- Scroll terminal output smoothly without snapping to whole lines.
- Open command history at the latest entry immediately, without an animated scroll.
- Keep selected block spacing aligned and avoid showing a sticky header before its command scrolls out of view.

### Known limitations

- Agent image attachments require a vision-capable model. Attach up to four images per message, each under 5 MB as PNG and 8192 pixels per side.
- Running CLI programs must support image paste from the macOS clipboard; drop one image at a time. Image paste replaces the clipboard contents.

## 0.1.12 — 2026-09-09

### What’s new

- Copy a conversation debug log from Agent’s conversation menu, including messages, tool results, and action rejection details to help diagnose failures. Review and edit the report before sharing; nothing is uploaded automatically.

### Fixes

- Treat capitalized requests such as “Install this program” as conversations, even when a similarly named shell command exists. Lowercase commands and explicit shell syntax still run in the terminal; Command-Return forces shell execution.

### Known limitations

- Rejected action details discarded by older versions cannot be recovered. New rejected responses retain bounded excerpts for debugging.
- Debug logs may contain private information from messages and tool output; review them before sharing.

## 0.1.11 — 2026-09-08

### What’s new

- Send natural-language requests to Agent automatically by default. Real shell commands continue to run in the terminal, and an existing preference to disable automatic routing is preserved.

### Fixes

- Keep typing responsive when another tab contains large, colored output such as Docker Compose logs.
- Reset the prompt cursor blink when typing letters or spaces so the cursor stays visible as you type.

## 0.1.10 — 2026-09-08

### What’s new

- Receive native macOS notifications when background terminal programs, including compatible CLI agents, request your attention. Click an alert to return to its tab.
- Control terminal alerts and check macOS notification permission in Settings → Terminal → Notifications.

### Fixes

- Keep typing responsive while command suggestions search large folders or command histories.
- Reduce the work needed to display long prompts and color shell input.
- Stop shell suggestions from interfering with fullscreen programs such as Codex CLI and Vim.
- Prevent delayed suggestions from replacing newer input or being accepted after you edit the command.

### Known limitations

- Notifications depend on the CLI emitting a supported signal and macOS allowing alerts.
- Very long shell input skips optional syntax coloring to keep editing responsive.
- Performance improvements were measured locally; responsiveness can still vary with shell plugins, displays, and other system activity.
- Agent conversations do not yet restore after relaunch. Large Agent histories can still load slowly.

## 0.1.9 — 2026-09-08

### What’s new

- Work with Agent independently in separate windows. Drafts, replies, and running requests stay with their window; stopping or closing one does not interrupt another.
- Close and quit warnings now include active Agent requests.

### Fixes

- Keep Agent settings and saved programs synchronized across windows.
- Preserve other windows’ program changes when editing the shared catalog.
- Prevent repeated “Previous session ended” banners from accumulating in restored terminal history.

### Known limitations

- Agent conversations do not yet restore after relaunch. Switching tabs within one window still stops that window’s active Agent request.
- Large Agent histories can still load slowly.

## 0.1.8 — 2026-09-07

### What’s new

- Restore terminal output, colors, and unfinished input after relaunching.
- Open independent windows with Command-N and restore their tabs and split layouts.
- Search terminal output, rename and reorder tabs, reopen closed tabs, and work in two side-by-side panes.
- See background command completion in the sidebar and receive a warning before closing a running task.
- Send commands to the shell by default, with optional automatic Agent routing in Settings.

### Fixes

- Show a useful explanation when Agent cannot recover a malformed response.
- Align the prompt chevron, caret, and placeholder with consistent sizing.
- Prevent multiple windows from competing over the active Agent conversation.

### Known limitations

- Relaunch restores saved output, not running processes. A crash can lose the latest ten seconds of output.
- Agent state is shared across windows. Large Agent histories can still load slowly.

## 0.1.7 — 2026-09-07

### What’s new

- Save reusable Agent workflows as local programs and run them again without
  using AI tokens.
- Find saved programs with @mentions, pass new URLs or other inputs, and
  choose a working folder for each run.
- Keep saved programs in a persistent catalog with backup recovery.

### Fixes

- Give Agent more specific feedback when an action is malformed so automatic
  retries can correct the problem.
- Reduce rendering work in long Agent conversations and inactive panes.
  Replies display plain text while streaming and format when complete.

### Known limitations

- Large conversation histories can still load slowly. Automatic scrolling
  is currently disabled; scroll down to see new replies.
- Saved programs currently stop after 60 seconds.

## 0.1.6 — 2026-09-07

### Fixes

- API errors now name the provider, explain what went wrong, and suggest what
  to do next instead of showing a generic failure.
- Distinguish exhausted API credits and spending limits from temporary rate
  limits, including a suggested wait when the provider supplies one.
- Explain when a conversation exceeds the model’s input limit or a reply is
  cut off by its output-token limit.
- Give clearer guidance for rejected credentials, model access, unavailable
  services, timeouts, and connection failures across Agent and voice errors.

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
