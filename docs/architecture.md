# Architecture

## Product boundary

Sora is a macOS-native terminal first. Local intelligence and AI are later layers, not prerequisites for terminal operation.

## V0 architecture

```text
macOS Application
├── SwiftUI application, window, and tab chrome
├── WorkspaceController (per window; owns tab list and PTY views)
├── AppKit terminal host view (plain NSView per tab)
├── Ghostty runtime coordinator (process-wide)
└── GhosttyKit / libghostty-internal
    ├── terminal state
    ├── Metal / IOSurface rendering (owns the view layer)
    └── PTY and shell process
```

PTY and shell ownership is confirmed: `ghostty_surface_new` creates the PTY and
launches the default shell. Sora does not open a PTY or exec `zsh` itself.

This uses Ghostty's internal embedder API (`include/ghostty.h`, imported as
`GhosttyKit`), not `libghostty-vt`. See
[`docs/libghostty-integration.md`](libghostty-integration.md).

## Target module layout

```text
Sora/
├── Application/
├── Terminal/
├── Workspace/          # Phase 2+
├── Commands/           # Phase 3+
├── Completion/         # Phase 4+
├── Intelligence/       # Phase 5+
├── Agent/              # Phase 6+
├── Providers/          # Phase 6+
├── Tools/              # Phase 6+
├── Storage/            # Phase 3+
└── Shared/
```

Only create directories required by the current phase. Phase 5 creates
`Application/`, `Terminal/`, `Workspace/`, `Commands/`, `Storage/`,
`Completion/`, and `Intelligence/`. The first Phase 6 slice adds `Agent/` and `Providers/`.

## Responsibilities

### Application

- app and scene lifecycle
- native windows and menus
- settings and keyboard shortcuts: the standard macOS Settings scene owns a
  scalable sidebar for Terminal, Agent, and Voice configuration. Agent views
  show current provider context and link to Settings but do not embed setup or
  credential forms in the conversation.
- updates: Sparkle performs one non-blocking check per Release-build launch and
  exposes a native “Check for Updates…” command. The stable feed is
  `appcast.xml` on GitHub's latest release; both the archive and feed are EdDSA
  signed by the release workflow. Each tagged version must have a matching
  human-readable section in `CHANGELOG.md`; packaging fails if it is missing,
  and the workflow publishes that section both in the GitHub release notes and
  as embedded Markdown in Sparkle's update-review window. Debug builds only
  check when asked manually.

### Terminal

- GhosttyKit bridge (`ghostty_app_t`, `ghostty_surface_t`)
- AppKit `NSView` host; libghostty owns the Metal layer
- surface lifecycle and teardown
- keyboard and pointer forwarding
- resize and backing-scale propagation
- clipboard: Cmd+C/V and Edit menu copy/paste via `ghostty_surface_read_selection` / `ghostty_surface_text`; OSC 52 via Ghostty runtime callbacks plus `NSPasteboard`
- terminal links: Ghostty detects plain URLs and OSC 8 hyperlinks, highlights them using its native macOS interaction, and sends activation through `GHOSTTY_ACTION_OPEN_URL`; the embedded runtime hands that action to `NSWorkspace` so links open in the user's default browser/application
- voice input: macOS Speech Recognition provides user-initiated dictation into
  editable terminal and Agent inputs without auto-submission. A separate
  OpenAI Realtime WebSocket controller owns bidirectional PCM audio, turn
  detection, playback, and tab-scoped transcripts; see `voice.md`.
- session chrome: flush two-column `HStack` (sidebar | terminal). Transparent titlebar with `fullSizeContentView` so close/minimize/zoom sit in the sidebar next to the collapse control. Collapsing the sidebar hides that column; the traffic lights, sidebar toggle, session title, path, and new-tab control move into a thin terminal header. Do not use `.toolbar(.hidden, for: .windowToolbar)` — that hides the window buttons. No `NavigationSplitView` (Tahoe draws that as floating rounded cards). Window frost is a square `NSGlassEffectView` behind both columns.
- shell presentation: `~/.hushlogin` suppresses `login(1)` "Last login"; a Sora `ZDOTDIR` sources Ghostty's zsh integration, replaces the stock macOS `user@host` prompt with an empty prompt (blinking bar cursor only), and colors the input line (command/flags/paths/strings) unless the user already has zsh-syntax-highlighting. The first command starts flush at the top with no spacer. After each command, zsh `precmd` prints a muted duration followed by two empty terminal rows. A small tracked patch adds Ghostty's opt-in `semantic-prompt-boundaries` renderer feature: its subtle one-pixel rules are derived from OSC 133 primary prompt rows, so they appear before the user types and share the terminal grid's reflow, scrollback, and clear-screen lifecycle. Empty historical prompt rows do not receive rules; the current live prompt keeps its boundary. The rule sits on the last device pixel of the completed block, flush with the transition into the next input region. Sora enables that option in `sora.ghostty`; there is no AppKit position cache or title-sequence sentinel. Unicode dashes are not used because they become terminal content and reflow. Paste and completion-accept inserts use `paste:none` so zsh's default paste standout does not paint spaces as opaque blocks. The bar cursor uses Ghostty's built-in blink (`cursor-style-blink = true`); a custom-shader soft fade was dropped because a failed shader load left blink disabled with a solid caret. Reduce Motion forces a steady bar via an overlay config. Chrome motion tokens are ease-in-out.

Unit tests must not link GhosttyKit. `GhosttyInput.swift` and `GhosttyClipboard.swift` stay Ghostty-free; `GhosttyInputKit.swift` and `GhosttyClipboardKit.swift` are app-only.

The host does not implement VT parsing, glyph rendering, or PTY spawn.

### Workspace

- tabs and the active session
- independent Ghostty surfaces / PTYs per tab
- basic restoration of tab working directories via `UserDefaults`
- split-pane architecture only after tabs are stable

### Commands and Storage

- structured command runs from OSC 133, not screen scraping
- SQLite history at `~/Library/Application Support/Sora/history.sqlite`
- command text from Ghostty zsh integration OSC 2 (preexec title)

### Completion and Intelligence

- prompt line tracked from keystrokes, not screen scraping
- history prefix completion ranked by cwd, git root, frequency, and recency
- filesystem path completion for tokens that look like paths
- inline ghost text; Tab / Right Arrow accept without sending those keys to the PTY
- Inline suggestions use a fixed prompt origin captured before the first keystroke. The tracked ASCII buffer determines the suffix column, so text and position change together without following intermediate PTY cursor redraws or running a polling timer. Untracked, non-ASCII, and wrapped input suppresses the overlay rather than guessing its position.
- overlay resets on Enter, Esc, arrows (except accept), Ctrl-C/U/A/E/K/W, Option-as-Meta (no printable text), and multiline paste. Ready-prompt mouse focus keeps tracking so conversational Return still sees the typed line. zsh Tab-complete and history recall desync the buffer until the next prompt.
- Agent-vs-shell routing does not use the keystroke buffer or the rendered grid. zsh mirrors its live ZLE `$BUFFER` to Sora on every `zle-line-pre-redraw` through a sentinel-prefixed OSC 2 title (`ShellEditLine`), which Sora consumes as routing state and never shows as a window or tab title. That buffer stays correct through paste, history recall, completion, and wrapping, and its arrival also proves the shell is at an interactive prompt. Screen scraping cannot substitute: `PS1` is empty, so nothing on screen marks where the prompt begins. Shells without the Sora hooks fall back to the keystroke buffer.
- next-command prediction on an empty prompt after a successful command, shown as accent `→` text in the sticky prompt footer under the grid (not as an overlay on scrollback). Esc or Up/Down/Left dismisses it until the next successful command. Prefix ghost text stays on-grid only while the live prompt is visible; scrolling away hides the overlay and mirrors the line in the footer.

### Agent, Providers, and Tools

The first Phase 6 slice uses `AskSession` for main-actor conversation state and
request cancellation, `AIProvider`/`AIRequest`/`AIEvent` for provider-neutral text
streaming, and `AIBackend` for the five available providers. `HTTPAIProvider`
shares URLSession transport across OpenAI Responses, Anthropic Messages, and
Vercel and xAI Chat Completions; adapters translate their distinct event schemas.
`CodexProvider` uses `CodexConnection` to run the installed official app-server
over stdio with an ephemeral, text-only thread. `CodexLogin` owns sign-in setup.
`AskView` is a translucent hybrid overlay on the live Ghostty surface (Agent →
Open Agent or prompt routing). Escape dismisses the overlay without stopping a
running answer; a reserved resume slot (and ⌘Y) sits above the sticky prompt
without resizing the PTY.
Each tab keeps its own in-memory agent thread, and a terminal→agent handoff
starts a fresh conversation for that tab. Storage is injected; credentials use
Keychain. Switching providers cancels outstanding work and restores that
provider's draft, model, and per-tab history. No tool interface is exposed in
this slice.
See [AI Ask](ai-ask.md).

`WebpageFetcher` is an explicit context input outside the provider adapters. It
accepts HTTPS HTML/text responses, does not use cookies or saved credentials,
caps the download, and never renders or executes the page. `WebpageText` removes
non-content blocks and creates a bounded static text snapshot. `WebpageLoader`
owns fetch cancellation and stale-result rejection; the user reviews that
snapshot in `WebpageAttachmentView` before attaching it to a question. The
attachment is stored with its user message and serialized as untrusted reference
data only when constructing a provider request.

The remaining target responsibilities are:

- application-owned agent loop
- provider-neutral request and event model
- provider adapters
- internal tool registry
- centralized permission decisions

## Planned core models

```swift
struct CommandRun: Identifiable, Sendable {
    let id: UUID
    let command: String
    let cwd: URL
    let startedAt: Date
    let finishedAt: Date?
    let exitCode: Int?
}
```

```swift
protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func isAuthenticated() async -> Bool
    func generate(
        request: AIRequest,
        onEvent: @escaping @Sendable (AIEvent) -> Void
    ) async throws
}
```

These are directional models for later phases. Do not add them during V0 unless the current implementation genuinely needs them.

## Architectural decisions

### macOS-native UI

SwiftUI provides application structure. A plain AppKit `NSView` hosts the
terminal. libghostty installs its own IOSurface/Metal layer onto that view.
Do not wrap a `CAMetalLayer` or `MTKView` around GhosttyKit.

### Swift-first implementation

Keep application logic in Swift until real boundaries emerge. A portable Rust core may be evaluated later for prediction or agent logic, but it is not a V0 dependency.

### Application-owned AI runtime

The future app owns context, tools, permissions, session state, and the agent loop. Models and provider services remain replaceable adapters.

### AI is optional

Disabling or removing every provider must not affect shell startup, rendering, history, completion, workspace features, or settings unrelated to AI.

## Terminal input and command blocks

The footer labels shell readiness as Ready or Running. Its nearly opaque dark
backing and accent rule remain legible over desktop wallpaper. Directory and
branch chips, input, and keyboard hints share the terminal's horizontal inset.
The panel starts at 112 points high and grows to six visual input rows.

ZLE owns the command buffer and reports its cursor offset through an escaped
title message. The panel preserves explicit newlines and wraps long lines at
measured grapheme boundaries, following the caret beyond six rows. Shift-Return
inserts a newline through the existing paste path; Return submits through zsh.
Ghostty suppresses live prompt rows and its grid caret while semantic shell
input is active. Submitted commands and alternate-screen programs render
normally. Keyboard events continue through the same Ghostty surface and PTY.

The panel displays only the authoritative shell buffer while typing. Completion
suffixes appear separately in the hint row when the tracked and authoritative
buffers agree and the caret is at the end. Next-command predictions appear only
when the buffer is empty. ZLE also reports whether the first token resolves in
the live shell using `whence`. Aliases, functions, builtins, and shell PATH
commands take precedence over implicit Agent routing; explicit `/agent`
requests retain their meaning. Alias definitions are not sent to the app.

Clicking input maps the visible row and nearest character boundary back to a
shell cursor offset, then forwards arrow keys. Custom arrow bindings can affect
positioning. Dragging selects visible input for Command-C; copying reads the
original buffer so visual wrapping adds no newlines. Selection follows terminal
semantics: typing clears the highlight and edits at the shell cursor rather than
replacing the selection. Drag selection does not auto-scroll. Clicking terminal
output clears the input selection so copying targets the output instead.

Semantic block boundaries remain in Ghostty's renderer and follow reflow and
scrollback. Completed blocks use charcoal (35, 38, 43 at 240/255 alpha); the
active region uses a darker base. Fills affect default-colored cells, preserving
selection and explicit ANSI backgrounds. Alternate-screen applications are
excluded. Backgrounds extend through window padding to the pane edges using
`window-padding-color = extend-always`. Text has 24-point horizontal and 18-point
vertical insets. The reserved Agent-resume strip shares the dark backing.

Two blank terminal rows follow the duration label; historical dividers sit
between them, a full terminal row above the command, balancing both sides; the live divider
is flush with the region transition. Empty historical prompts receive no rule.
Empty Return at a primary ZLE prompt is ignored without advancing the grid. The
accept-line wrapper preserves the previously configured widget for nonempty
input and continuation prompts. Interactive programs bypass ZLE and retain
ordinary Return behavior; whitespace-only input retains shell semantics.

Hint messages settle for 150 ms before replacing the visible hint, avoiding flashes between transient keystroke-tracking and shell-mirror states. The hint row stays visible while editing.

Shell-mirror updates render input immediately, independently of deferred completion refreshes. Key events reach the PTY before completion lookup, queued refreshes coalesce, and directory/branch context is cached until the shell reports its working directory again. Hint settling never gates input rendering.

Divider padding depends on whether the prompt is actual visible live input, not merely the last prompt in the viewport. Historical commands retain their spacing when the live prompt scrolls off-screen.

Provider failures are classified from bounded structured HTTP error bodies (up to 64 KiB) and streaming error events. User messages identify the provider, distinguish exhausted credits from temporary throttling, explain input/output token limits, authentication/access/model failures, and service/network failures, and suggest an action. HTTP status is retained; raw provider bodies and credentials are not displayed. Numeric Retry-After values are honored in the suggested wait. These messages do not automatically retry requests or spend additional API credit.

### Reusable program catalog

`AgentProgramStore` owns an atomic local JSON catalog. `AskSession` owns save/run
approval and integrates a provider-neutral `SORA_PROGRAM` envelope alongside
commands and webpages. Strict JSON parsing and a bounded script/name/description
schema keep multiline scripts separate from the single-line command envelope.
Unknown IDs never execute. Only metadata enters later provider requests; script
source stays local unless it is part of the current generation conversation.
Catalog runs skip the provider continuation and use the existing bounded command
runner. Generated script files are regenerated from catalog source at each run,
with private file permissions. This deliberately delivers reusable local scripts
before adding parameter forms or a separate job scheduler.


Program replay accepts a bounded array of literal arguments. Each argument is
individually shell-quoted by the store, and the same path handles catalog input
and agent-proposed inputs. The editor uses one argument per line, without shell
parsing or evaluation. Optional proposal arguments preserve compatibility with
previously saved conversations and programs.

Action repair now includes the rejected assistant response plus concrete validation
feedback, rather than repeating the same generic user prompt. The excerpt is capped
at 12 KB and fits inside the existing request context budget. Only the latest failed
attempt is included, so successive repairs cannot grow the transcript indefinitely.
Second-attempt guidance changes strategy while the two-retry execution guard remains.

### Agent transcript hang mitigation

The September 7 hang report sampled the main thread consuming CPU in SwiftUI
AttributeGraph / LazySubviewPlacements for the entire sample after a 647-second
hang. This identifies layout churn, not a blocked API or process wait; the exact
trigger cannot be recovered from that sample alone. Agent now uses an eager stack
with the newest 40 messages initially mounted and an explicit Show earlier messages
control. Full conversation data remains retained. Streaming scroll updates remain
coalesced but no longer animate while row heights change, removing overlapping
scroll/layout animations from this path.

### Long-transcript stress fixture (Debug only)

Launch the Debug executable with `--sora-transcript-stress-test`, then open Agent.
It creates 302 synthetic messages with 100-line output disclosures and emits 240
updates at a nominal 50 ms interval. Provider sends and transcript persistence are
disabled in this mode. Check completion, expand command output, and use Show earlier
messages. Quit and launch normally afterward. Completion prints
`SORA_TRANSCRIPT_STRESS_COMPLETE` (stdout can remain buffered until quit).

The live test exposed expensive Markdown/path parsing, redundant native pane/title
updates, and hidden Agent hosts observing the shared session. Hidden panes now host
EmptyView, the overlay disables intrinsic sizing, and unchanged titles/frames do not
republish. Completed Markdown uses one attributed Text instead of one view per block;
streaming stays plain until complete. Automatic transcript scrolling is currently
removed. Code fences retain text styling but no separate background container.

The revised 302-message run completed all updates and output expansion/older-message
loading remained interactive afterward. Initial bulk layout remains slow and logs
still contain AttributeGraph cycle warnings; this is not a clean responsiveness pass.
Further work should isolate those warnings and bulk-load latency. All 198 existing
tests pass, but those unit tests do not certify UI responsiveness.

## Terminal history restoration

Workspace snapshots retain stable tab IDs. Ghostty scrollback with SGR text styling is
checkpointed every ten seconds and on normal workspace shutdown, capped at
2 MB per tab, in private Application Support/Sora/TerminalHistory files.
The zsh bootstrap prints that text once before starting the new prompt; it never
evaluates archived text. Colors and text styling are restored; running processes are not. Ghostty’s VT export is captured without modifying the clipboard, and non-SGR terminal escape sequences are removed before saving. Older plain-text archives remain readable. A crash
may lose output since the last checkpoint. Older versions did not save output
and cannot supply previously lost history.

## Everyday terminal controls

- Cmd-F opens native output search. Ghostty owns matching, highlighting, and
  match navigation, including restored output. Return/Shift-Return navigate.
- Cmd-T creates a tab. Tabs can be renamed and moved up/down from their context
  menus. Cmd-Shift-T reopens up to ten recently closed tabs in the current window.
  Names and ordering persist; reopening creates a new shell with archived output.
- Cmd-D creates a two-pane side-by-side view with a draggable divider. Clicking
  either pane selects its terminal. Cmd-Shift-D returns to one pane without
  closing the other session. The pair and divider position persist across relaunch. Arbitrary nested splits are not implemented.
- Tab/window close and application quit ask before terminating a running child
  process. Background command completions appear as sidebar status text.
- Shell input is the default destination for Return. Automatic natural-language
  routing is opt-in under Terminal Settings; explicit /agent remains available.
- Drafts are saved alongside terminal history (100 KB per tab, private files).
  The first ZLE line-init hook reads them directly into BUFFER without evaluation.
  This hook is independent of which syntax highlighter the user has installed.

Cmd-N opens an independent terminal window. Each window has a stable UUID and
its own tabs, selection, split pair, divider position, and frame in the window
catalog. Existing single-window snapshots migrate with their tab IDs intact.
Closing a window removes its restoration record; quitting preserves all open
windows. Invalid catalog data is backed up before migration recovery. Each window owns its Agent session, including drafts, provider requests, command
execution and cancellation. Switching windows does not bind or stop another
window’s session. Closing a window explicitly stops only its Agent work. Close
and quit warnings include Agent requests as well as terminal processes.
Settings and Keychain credentials remain shared. Sessions observe preference
changes and apply only changed values; disabling Agent stops all sessions.
Provider changes intentionally stop the affected sessions. Program catalog
notifications refresh all windows, and each edit reads the current catalog before
writing so stale in-memory lists cannot discard another window’s changes.
Agent conversation snapshots are stored under AgentWindows/<window UUID> to
avoid cross-window overwrites. Tab conversations are still only restored within
the current app run; these snapshots are not yet a persistent conversation browser.
Named terminal profiles remain deferred.
Terminal OSC 9 / OSC 777 desktop requests and BEL signals now feed native macOS
notifications through `TerminalNotificationController`, independently of Agent.
Signals also set the existing tab attention badge. The focused terminal stays
quiet; background tabs/windows can notify even while Sora is active. Delivery is
limited to once per surface per five seconds. Permission is requested on the
first eligible signal, with failures logged and denied permission leaving badges
available. Clicking a notification selects its live originating tab/window;
closed sessions are not restored. No terminal output is scraped for notifications.
macOS notification settings control banners and sounds. Terminal Settings adds a
persisted, default-on alert toggle, live macOS permission status refreshed on
activation, an explicit permission request, and a System Settings shortcut.
Disabling alerts prevents authorization prompts and native delivery while
retaining tab badges; queued authorization callbacks recheck the preference.

Prompt cues derive their vertical placement from the native text field baseline.
The chevron uses the input font cap height, and the caret uses its ascender and
descender, keeping placeholders, suggestions, and wrapped input aligned.

History checkpoints omit the standalone restore banner and its launch spacer.
Only the fresh shell prints a session boundary; previously accumulated banners
are cleaned on the next checkpoint and disappear on the following relaunch.
SGR styling and other output are retained.
