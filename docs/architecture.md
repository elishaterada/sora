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
- versioned, atomic workspace files in Application Support; legacy `UserDefaults` migration
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
- next-command prediction on an empty prompt after a successful command, shown as accent `→` text in the sticky prompt footer under the grid (not as an overlay on scrollback). Esc or Left dismisses it until the next successful command. Up/Down opens history and hides the prediction while browsing. Prefix ghost text stays on-grid only while the live prompt is visible; scrolling away hides the overlay and mirrors the line in the footer.

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
commands take precedence over implicit Agent routing for lowercase input.
Capitalized input is conversational even when `whence` recognizes a command;
explicit shell syntax and Cmd-Return still force shell execution. Explicit `/agent`
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

Two blank terminal rows follow the duration label. Dividers split them between
adjacent blocks, leaving one blank row below the duration and one above the next
command. The live input region uses the same boundary. Empty historical prompts
receive no rule. Boundaries never borrow a nonblank or soft-wrapped output row.
Empty Return at a primary ZLE prompt is ignored without advancing the grid. The
accept-line wrapper preserves the previously configured widget for nonempty
input and continuation prompts. Interactive programs bypass ZLE and retain
ordinary Return behavior; whitespace-only input retains shell semantics.

Hint messages settle for 150 ms before replacing the visible hint, avoiding flashes between transient keystroke-tracking and shell-mirror states. The hint row stays visible while editing.

### Command history picker

`CommandHistorySession` owns a transient history preview for a focused, ready
input with Sora's ZLE integration. `CommandHistoryStore.recall` queries SQLite
on a worker queue for the latest 200 distinct commands matching a literal prefix,
ordered by last use within the current tab. Runs carry the workspace tab's stable
UUID, so restored and reopened tabs retain their own picker history. New tabs
start empty, even in the same directory. A nullable SQLite column migrates old
records without guessing their original tab; these remain in the global History
window. Completion suggestions continue to use the global history statistics.
Failed commands remain
recallable. This uses Sora's recorded history; it does not import shell history
files. Request identities discard late results after dismissal or a new query.
Loading, empty, and failure states are explicit, and arrows remain responsive
while loading. New entries use an encoded preexec command report, preserving
newlines and tabs that ordinary window titles remove. Older title-only multiline
records cannot have their missing line breaks reconstructed from this database.

`CommandHistoryPopoverView` is a native table overlay above the sticky input.
It leaves terminal dimensions and the first responder unchanged. At short
window heights the picker uses the available area above input and reduces its
header/footer before sacrificing rows, keeping selection visible even above a
six-line draft at the minimum workspace height. Newest entries
appear at the bottom; selection scrolls into view. The sticky input previews the
selected command, with completion ghosts suppressed, while ZLE retains the
original draft and cursor. The input height stays fixed during preview; long
commands scroll to the caret within those rows instead of reflowing the PTY.
Escape, Down beyond the latest, switching panes, or
entering block/Agent mode dismisses the preview without changing that draft.

Return stages the selected command with the existing whole-buffer ZLE widget
and paste path, then sends one shell Return, bypassing conversational routing.
Tab, a row click, or editing stages the command without executing it. No-match
Return dismisses the list and follows the ordinary draft submission path.
Control-P/N remain native shell history controls. In multiline drafts, Up/Down
enter history only from the first/last logical line respectively.

### Command block keyboard focus

`CommandBlockInput` routes Cmd-Up from a ready shell prompt into completed
blocks. Unmodified input arrows belong to command history, with ordinary ZLE
cursor movement preserved within multiline drafts. Up/Down navigate selected
blocks; Escape or Down beyond the latest block returns to input. Typing/paste
resumes the unchanged draft at its existing cursor. Running programs bypass
block routing, with an additional alternate-screen check inside Ghostty.
ZLE line-init publishes the current buffer after draft restoration so Control-C
cannot leave stale input text affecting routing on the next prompt.

`CommandBlockActionsView` is a separate native first responder in the existing
36-point resume slot. Selection hides the input caret and shows a full-width
Ghostty selection plus copy/reuse/menu controls. The grid does not resize when
selection changes. Single clicks select blocks; dragging and multiple clicks
retain Ghostty text selection. Right-click and Tab expose the same native menu,
including Copy Command, Copy Output, Copy Entire Block, and Save Output. AppKit
copy/paste commands are forwarded by the block responder.

Block highlights and pointer hit testing use the divider boundaries, including
the leading spacer and excluding the next block's spacer. The tracked selection
retains its semantic command/output bounds for navigation and copy/reuse actions.
Ordinary text selections keep their exact cell bounds. The renderer computes the
visual range under the terminal lock and draws from its own snapshot.

The existing Ghostty patch adds small embedded API entry points over OSC 133
prompt/input/output metadata and tracked selection pins. Swift does not keep a
second scrollback model or infer boundaries from displayed text. The next prompt
closes a block, empty prompts are skipped, and missing/pruned metadata is not
guessed. Reflow now marks additional physical prompt rows as continuations and
preserves the primary marker when widening. This prevents a wrapped command
from becoming several independently selectable blocks.

Actions read current selected text on demand, trimming trailing grid padding.
Output includes the shell-generated duration footer. Return/Use Command stages
the semantic input text through the existing paste path, after a bundled
Control-X Control-R ZLE widget clears the entire draft into CUTBUFFER. No
accept-line is sent. The widget is bound in emacs, vi insert, and vi command maps.
No AI calls are involved. Archives now preserve passive OSC 133 metadata, so
clicking a restored block enters the same responder and arrow navigation as a
new command. Older archives that already lost their metadata remain searchable
and text-selectable; their missing command boundaries cannot be reconstructed.

Shell-mirror updates render input immediately, independently of deferred completion refreshes. Key events reach the PTY before completion lookup, queued refreshes coalesce, and directory/branch context is cached until the shell reports its working directory again. Hint settling never gates input rendering.

Divider spacing stays consistent when the live prompt scrolls off-screen. The
last visible historical command is not mistaken for live input.

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
streaming stays plain until complete. H7 restores conditional transcript following with an AppKit scroll observer;
scrolling up preserves the reading position and exposes a New response control. Code fences retain text styling but no separate background container.

The revised 302-message run completed all updates and output expansion/older-message
loading remained interactive afterward. Initial bulk layout remains slow and logs
still contain AttributeGraph cycle warnings; this is not a clean responsiveness pass.
Further work should isolate those warnings and bulk-load latency. All 198 existing
tests pass, but those unit tests do not certify UI responsiveness.

## Terminal history restoration

Workspace snapshots retain stable tab IDs. Ghostty scrollback with SGR text styling is
checkpointed every ten seconds, before Sparkle installation/relaunch, and on workspace shutdown, capped at
2 MB per tab, in private Application Support/Sora/TerminalHistory files.
The zsh bootstrap prints that text once before starting the new prompt; it never
evaluates archived text. Colors, text styling, and command boundaries are restored;
running processes are not. The embedded archive export reads the primary screen
under Ghostty's terminal lock, even during fullscreen programs. Its opt-in VT
formatter emits prompt/input/output markers with `aid=sora-archive`, including
empty closing prompts and multiline continuations. The stream handler restores
their grid metadata without generating command-start/finish events. Ordinary
copy/export formats keep their existing behavior. The sanitizer allows only SGR
and those four exact passive OSC 133 forms; titles, clipboard actions, command
completion notifications, and other escapes are discarded. Older plain-text
archives remain readable. A crash
may lose output since the last checkpoint. Older versions did not save output
and cannot supply previously lost history.

## Everyday terminal controls

A native sticky command header overlays the top of the terminal without changing
PTY dimensions. A read-only Ghostty snapshot finds the semantic command above
the viewport, its signed position, and the distance to the next command, including
fractional scroll offsets. The header follows the command into its pinned position
and is pushed away by the next command. Geometry updates synchronously with the
scroll position, without delayed animations or a whole-row visibility threshold.
At the start of scrollback the normal command remains visible until its source
crosses the pinning point; the initial unscrolled row never activates a header.
Two clipped header views share the same top band so the incoming command is
visible while it pushes the outgoing command away. It follows completed, restored, and running
commands, hides on the alternate screen, and never changes the current selection.
Long/multiline commands use a single truncated line with the full command in a
tooltip and accessibility value. Older archives without semantic markers cannot
supply sticky headers.
The snapshot exports Ghostty’s cell styling with palette colors resolved to RGB.
Native headers retain those colors and font traits, use the surface font, and
match the completed-command background. A bounded cache avoids parsing the same
style runs during scrolling and is cleared when the terminal font changes.

Trackpad scrollback uses Ghostty's opt-in `smooth-scrolling` path. AppKit precise
deltas are converted from points to backing pixels at the view's actual scale.
The primary screen retains a fractional viewport row alongside its tracked
integer viewport; macOS continues to supply gesture and momentum events. Limits
clamp immediately without overscroll debt. Discrete scrolling, fullscreen
applications, and mouse-reporting programs retain Ghostty's existing routing.

The render snapshot includes the partially visible bottom row without changing
PTY dimensions. The renderer shifts its projection and background sampling by
the same pixel offset, including block dividers and selection colors. Pointer
hit testing reads that offset under the terminal lock, including the extra edge
row. Fraction-only frames reuse existing glyph rows. Keyboard/block jumps,
return-to-input, resize, and screen reset restore row-aligned positioning.

- Cmd-F opens native output search. Ghostty owns matching, highlighting, and
  match navigation, including restored output. Return/Shift-Return navigate.
- Cmd-T creates a tab. Tabs can be renamed and moved up/down from their context
  menus. Cmd-Shift-T reopens up to ten recently closed tabs in the current window.
  Names and ordering persist; reopening creates a new shell with archived output.
- Cmd-D splits the selected pane side by side; Split Terminal Below adds a
  vertical split. A nested pane tree supports up to eight panes, directional
  focus, draggable dividers and maximizing a pane without closing its siblings.
  The tree, divider positions and maximized state persist across relaunch.
- Tab/window close and application quit ask before terminating a running child
  process. Background command completions appear as sidebar status text.
- Automatic natural-language routing is enabled by default under Terminal
  Settings, preserving explicit opt-outs. Lowercase known commands stay in the shell;
  explicit /agent remains available, and Cmd-Return forces shell execution.
- Drafts are saved alongside terminal history (100 KB per tab, private files).
  The first ZLE line-init hook reads them directly into BUFFER without evaluation.
  This hook is independent of which syntax highlighter the user has installed.

Cmd-N opens an independent terminal window. Each window has a stable UUID and
its own tabs, selection, split pair, divider position, and frame in the window
catalog. Existing single-window snapshots migrate with their tab IDs intact.
An explicit, approved window close removes its restoration record; quitting and
incidental window teardown preserve open windows. The versioned catalog lives in
Application Support with atomic writes, a valid prior checkpoint, stale-writer
rejection, and visible errors. Original preference snapshots remain available
after migration. See [workspace durability](workspace-durability.md) for the
failure investigation and signed update verification. Each window owns its Agent session, including drafts, provider requests, command
execution and cancellation. Switching windows does not bind or stop another
window’s session. Closing a window explicitly stops only its Agent work. Close
and quit warnings include Agent requests as well as terminal processes.
Settings and Keychain credentials remain shared. Sessions observe preference
changes and apply only changed values; disabling Agent stops all sessions.
Provider changes intentionally stop the affected sessions. Program catalog
notifications refresh all windows, and each edit reads the current catalog before
writing so stale in-memory lists cannot discard another window’s changes.
Agent conversation checkpoints are stored under
AgentWindows/<window UUID>/Tasks/<tab UUID>, with separate files per provider.
Transcripts and goals restore across launches; unfinished work waits for explicit
Resume. Switching tabs keeps the originating task running. Older shared snapshots
remain untouched because their original tab cannot be inferred reliably.
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

History checkpoints omit the standalone restore banner, its launch spacer, and
trailing unsubmitted prompts; drafts are saved separately without execution.
Only the fresh shell prints a session boundary; previously accumulated banners
are cleaned on the next checkpoint and disappear on the following relaunch.
SGR styling and other output are retained.


### Input performance

Completion lookup runs on a serial worker, retaining only the latest pending
request and rejecting results after edits, directory changes, or command start.
The worker only uses the FULLMUTEX history connection's query methods; UI-facing
history publication stays on the main thread. Fullscreen input bypasses shell
completion. The bundled zsh preexec hook sends a command-start sentinel so a late
ZLE redraw cannot leave prompt routing active while a command runs. Prompt layout
caches unchanged wrapping and bounds text-shaping calls. Optional zsh coloring
stops above 1,024 characters to keep large buffers editable.

See [input performance](input-performance.md) for measured baselines, stress
tests, reproducible commands, and measurement limitations.

## Terminal image drops

`TerminalPaneView` accepts native image file URLs, PNG/TIFF data, and image file
promises over both the renderer and prompt bar. Drops over the Agent overlay
attach images to its draft instead of sending terminal input.
`TerminalImageDrop` resolves them to validated local files, with separate durable
Application Support directories for generated/promised images. It never uploads images. Existing files are referenced in place.

At a ready shell prompt, each shell-quoted path is sent separately through
Ghostty's text/paste API. While a program is running, Sora instead writes binary
PNG and TIFF representations (no URL/text flavor) to the general pasteboard and
sends Control-V. Codex CLI reads the pixels through its native clipboard API.
Command-V with an image on the clipboard follows the same route. Running programs
accept one image per drop; the image remains on the clipboard because there is
no reliable acknowledgement of when another process has finished reading it. Control characters in
filenames are rejected; drops never insert Return. Promise callbacks retain the
original target session identity and do not redirect to a newly selected tab.
Receive failures are presented as native errors. Generated images are retained
so references remain valid after relaunch; automatic cleanup is not implemented.
Binary image paste requires a local program supporting Control-V image paste;
this does not transfer image data over SSH. Shell paths likewise refer to local files.

Agent images are optional binary PNG attachments on AIMessage, preserving compatibility with older saved messages. Responses, Anthropic, chat-completions, and Codex app-server requests encode the actual image data rather than local paths. Conversation image context is capped at 20 MB; drafts are not submitted by a drop. Local terminal programs receive PNG/TIFF on the native clipboard plus Ctrl-V, while shell prompts retain quoted file-path insertion.

### Failed command backgrounds

OSC 133 command completion with a positive exit status marks the command's rows
in Ghostty's primary screen. A muted red fill replaces only the default block
background; explicit application backgrounds and selection remain intact. The
native pinned header reads the same failure metadata. Success, missing status,
and running commands retain the neutral fill. No AI service is involved.

Failure metadata follows rows through scrollback and reflow. Sora's VT archive
preserves it with an internal `OSC 133;D;1;aid=sora-archive-row` marker, replayed
without command-completion notifications. The packed row remains 64 bits.

### H7 transcript follow verification (2026-09-12)

The 302-message fixture completed all 240 updates with conditional following.
Scrolling up held the reading position and exposed New response; that control
returned to the bottom. Output expansion remained responsive. Loading 40 older
messages preserved the visible region around request 131. AttributeGraph cycle
warnings already documented above still occur in the bulk fixture; this is a
behavioral pass, not a claim that the earlier layout-warning debt is resolved.


## Saved terminal commands

`SavedCommandEditor` is a shared native review dialog for command blocks, the
History window, and Ctrl-R search. It writes through `AgentProgramStore` without
requiring an Agent session. Each save reads the current catalog and rejects name
collisions; scripts stay literal. The command palette can insert saved scripts
into a ready shell, including from block browsing, without executing or changing
folders. Running programs retain input ownership. Existing Programs storage,
validation, backups, and review/deletion UI are reused; there is no second catalog.

### Contextual command completion

`CommandCompletionRequest` recognizes a bounded, plain-shell subset: Git
subcommands/local branches, package-manager `run` scripts, and a small authored
flag catalog. `CommandCompletionEngine` reads local refs (including worktree
`commondir` and packed refs) and the nearest package manifest. It never runs Git,
package scripts, provider calls, or network requests. Reads are bounded; large or
invalid files expose an error with shell completion available.

`CommandCompletionSession` permits one worker lookup and one newest queued
request. Cancelled or obsolete results cannot update the nonactivating AppKit
child menu. `GhosttySurfaceView` checks the originating line, caret, directory,
and input ownership before showing or accepting results. Tab opens choices or
inserts a sole match. Up/Down selects; Return/Tab inserts, without execution;
Escape preserves the draft. Typing dismisses the menu, and another Tab requests
choices for the edited prefix. Mouse, paste, tab/window changes and command start
cancel the pending lookup. Edit → Show Command Completions is also discoverable
through the command palette.

Aliases, quoted/compound input, non-final caret positions and unsupported
commands retain the existing completion path. The menu offers an explicit shell
fallback. Package/branch names are shell-quoted when needed; lightweight path
suggestions escape spaces and metacharacters and defer complex quoting to zsh.
This is a focused catalog, not a replacement for installed shell completion
plugins, remote completion, or every option of every CLI.

### Appearance preferences

T10 adds installed monospaced font families, Dark/Light/System appearance, and
compact spacing. Dark/SF Mono/18 pt remains the default. The selected font is
validated against native installed families before generating configuration, so
preferences cannot inject Ghostty settings. A blank font-family entry replaces
the bundled family instead of appending another fallback. Each configuration
load uses a unique temporary overlay, removed immediately after parsing; it
cannot overwrite another running app's overlay.

`GhosttyRuntime` loads a fresh bundled configuration plus preferences, reports
parse/reload errors, and uses libghostty's existing app configuration update API
to propagate changes to every surface without replacing sessions. Native chrome,
Agent/history windows, input, command headers and separators share adaptive
colors. System appearance changes use AppKit's effective-appearance observation.
Font/spacing changes remeasure wrapped input and keep its caret geometry aligned.
Light chrome uses an opaque base to stay readable over dark wallpapers.

The existing MIT-licensed Ghostty integration patch now selects light or dark
semantic block fills from the terminal background; explicit program backgrounds
and selections remain authoritative. Its source and rebuilt framework are kept
in sync through `scripts/build-ghosttykit.sh`. Command duration and Agent markers
use palette colors so future output follows the theme. Existing archived explicit
RGB styling remains literal; changing theme does not rewrite historical output.

### App keyboard shortcuts

`GhosttyRuntime` owns one `AppShortcutStore`; SwiftUI command groups observe it
and use the same bindings shown in Settings and the command palette. Native
terminal key forwarding yields to configured app commands. Terminal editing,
tab-number keys, standard app actions and the opt-in global show/hide shortcut
keep their separate behavior. Agent/close hints follow the configured bindings.

Settings records a chord with an app-local event monitor only while its explicit
Record Shortcut control is active in the key window. Escape, changing action,
closing Settings or switching windows ends recording. No global listener is
installed. Bindings require Command and a supported key, and are checked against
other managed shortcuts, reserved terminal/standard actions, and existing native
menu items before persistence. Reset can report an occupied default; Reset All
restores the whole set together. Malformed or conflicting saved catalogs expose
an error and preserve their original bytes until an explicit edit/reset.


### Named project layouts

`ProjectLayout` stores only names, folders, selected tab and pane arrangement.
Opening always assigns new window/session identities and never reads a source
terminal archive, draft or Agent task. `ProjectLayoutStore` keeps a versioned
JSON catalog in Application Support/Sora/Layouts (isolated per development bundle),
with a lock, atomic private writes, synchronized files/directories and a validated
backup. Fresh reads merge independent changes; record revisions reject stale
rename/delete. Unknown versions are preserved, and corrupt-primary recovery
preserves the unreadable bytes and exposes a recovery message.

File menus and the command palette save/open layouts; the native manager reviews,
renames and deletes them. Missing directories require an explicit replacement,
Home fallback, or Cancel. Replacements affect this opening only. The new workspace
is durably seeded before opening its window. Templates are bounded to 50 layouts
and 64 tabs per layout; startup commands are outside this slice.


### Nested terminal panes

`PaneLayout` is a bounded binary tree with right/below branches, stable divider
identities and per-branch ratios. Workspaces use session UUID leaves; project
templates map them to tab indices and assign new UUIDs when opened. Existing
two-pane snapshots migrate into the tree without changing session IDs. New
snapshots preserve the tree and maximize state; malformed trees fail decoding
through the existing protected workspace recovery path.

`WorkspaceHostView` owns flat, stable AppKit pane views and lays them out from
the tree. Resizing, focus changes and maximize never reparent or replace terminal
surfaces. Dividers expose drag and accessibility increment/decrement; mouse-up
commits the ratio immediately, while normal checkpoints cover interrupted drags.
Keyboard focus uses adjacent pane geometry; closing a pane collapses its branch
and focuses a neighboring survivor. Other tabs and their histories remain intact.
Switching to a separate tab retains the window's arrangement, and selecting one
of its pane tabs reveals it again. Return to Single Pane explicitly clears the
arrangement without closing its sessions.

One window has one saved pane arrangement, up to eight visible panes. New splits
require enough room for roughly 220 points per child along the split axis; smaller
restored windows may compress panes, with maximize available for reading. Four
Control–Command–Arrow actions, Option–Command–D for below, and Control–Command–M
for maximize join the editable shortcut catalog. Arrow identity uses native
navigation key codes when the keyboard layout translator returns no character.
The active pane alone receives the accent input edge and caret.


### Block bookmarks

A bookmark is an immutable plain-text copy of one selected command block's
output, retained until explicit deletion. It does not depend on a Ghostty pin,
scrollback row number, a source tab staying open, or terminal archive retention.
The native library opens that copy and can activate its source tab if still open;
it does not claim to relocate an expired block within the terminal. Source folder
metadata describes the tab at capture time, not an inferred historical directory.

`BlockBookmarkStore` uses a private SQLite file under the same stable app-support
namespace as layouts. Transactions merge independent saves; an immutable digest
avoids duplicate captures within one tab. The first 1 MB is saved at a UTF-8
boundary for large blocks, explicitly marked as an excerpt. The 200-copy limit
rejects new saves rather than evicting old output. Unknown database versions and
unreadable files are left in place with visible errors. The library loads only
one output body at a time; metadata search and read-only AppKit text need no AI.

Native utility windows exposed a focus-ownership issue in SwiftUI's cached
FocusedObject. Workspace/menu actions now verify the actual key window before
mutating tabs; the Close action falls back to closing the active utility window.
The bookmark window also handles its own Command-W/Command-F/Escape with a local
monitor restricted to that window and removed when it closes. This prevents
closing or editing a background terminal through a utility-window shortcut.


### Output search and matching-line snapshots

The native Find panel offers Terminal and Selected block scopes. Whole-terminal
search stays in Ghostty, including authoritative selected/total match callbacks.
Selected-block search reads Ghostty's block text into a read-only AppKit reader;
Only matching lines does the same for either scope. Filtering never edits the
terminal or changes PTY output. Show All Lines explicitly resets the filter, and
Refresh Snapshot recaptures live output. Escape/Command-W return focus to the
source input or selected block; surface teardown dismisses the panel.

Snapshots are labeled with capture time, scope and excerpt status. They retain
the first 1 MB at a valid UTF-8 boundary. Literal case-insensitive search uses
UTF-16 ranges for AppKit, caps navigation at 10,000 matches and filtered output
at 10,000 matching lines, and labels either cap. One background worker keeps
only the newest pending request; revisions discard obsolete or canceled results.
Matching lines remain verbatim without inserted line-number matches. Native
selection prefills the query, bounded to 512 characters; selecting an entire
command block chooses block scope instead. The floating panel stays within its
screen and handles Return/Shift-Return navigation without submitting shell input.


### Shell capabilities and remote context

See [shell integration](shell-integration.md) for the supported capability matrix.
Sora separates a shell's semantic command markers from its editable-input mirror.
Ghostty's new per-surface native-input flag defaults off and is enabled only by
an authoritative edit-line report. This preserves the visible grid prompt and
cursor in Bash and unintegrated nested shells while keeping semantic block
styling, navigation and search. Command start returns input rendering to Ghostty.

Bounded shell context reports carry shell, locality, host and path. A detected
SSH/mosh/telnet process overrides local claims; remote reports are bound to its
foreground process identity. Remote paths are display-only, never local file
URLs. Remote input stays with the remote shell; local completions, recall,
Agent entry and image-path insertion cannot operate against that context.
New tabs and saved workspace folders retain the last local location. Remote
output archives preserve command boundaries, but unsubmitted remote drafts
are excluded from local relaunch and remote commands from the local recall index.

The optional native Shell Integration window copies activation commands and
exports a complete source folder. The export is staged and renamed atomically,
refuses an existing destination, and preserves the bundled Ghostty sources and
licenses. No SSH connection or startup-file edit occurs during export. Bash
keeps Readline input; its adapter handles command identity, history exclusions,
exit status and display-only archive replay. Native helpers and the command
index now use the same stable bundle namespace as the workspace catalog for
verification builds. The production `Sora/history.sqlite` location is unchanged;
terminal archive identities remain stable UUID filenames.
