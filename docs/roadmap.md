# Roadmap

## Current priorities and how to use this roadmap

Updated 2026-09-12 after reviewing Sora against Warp and the user's request for
an Agent that carries work through to a verified outcome.

The tab/history durability regression is fixed and verified in
[workspace durability](workspace-durability.md), including a signed local Sparkle
update followed by quit and reopen. H1–H8, T01–T14 and U01–U04 are complete.
T06's physical show/hide shortcut passed the user's Space and display checks;
the possibly manual resize is documented as an inconclusive frame comparison.
Release target: **Sora 0.2.0**. The release review fixed interrupted native-read
recovery and stale architecture notes; all 361 tests and the packaged Apple
Silicon Release build passed. Publication follows [releasing](releasing.md);
see the [0.2.0 release page](https://github.com/elishaterada/sora/releases/tag/v0.2.0)
for availability. The next issue is **expand Agent recovery evaluation fixtures**.
Complete one vertical slice at a time; Phase 0 through Phase 4 remain complete.

Unchecked items are planned, not shipped. Check an item only after its acceptance
criteria, relevant build/tests, and applicable manual checks pass. Record the
completion date and verification or release reference alongside the item. If
only part ships, split the remaining work into unchecked child items instead of
checking the whole feature. H IDs identify harness work; T IDs preserve the
terminal comparison's ROI order; U IDs track the additional UX details.

The [Agent harness design](agent-harness.md) explains behavior, dependencies,
completion evidence, permissions, recovery, and evaluation. Implementation and
measured outcomes are recorded in [harness verification](verification-agent-harness.md).

## Durability regression

- [x] **D01 — Preserve tabs and history across installs, launches, and updates.**
  Versioned atomic workspace files, legacy migration, backups, stale-write
  rejection, explicit-close handling, update/quit flushing, and startup/draft
  archive protection. Verified 2026-09-12 with 321 tests, native migration and
  forced-termination checks, and a signed local Sparkle installation followed by
  quit/reopen. See [investigation and verification](workspace-durability.md).
  Production release remains separate from implementation verification.

## Phase 0: integration decision

- inspect current Ghostty and Ghostling sources
- confirm supported `libghostty` embedding path
- document build, API, rendering, lifecycle, and licensing constraints
- create a short decision record

Exit: a concrete integration path with no unresolved foundational ownership question.

**Status (2026-09-03):** complete. PTY/shell ownership belongs to GhosttyKit
(`ghostty_surface_new`). `libghostty-vt` / Ghostling is rejected for V0.
Details: [`docs/libghostty-integration.md`](libghostty-integration.md).
Phase 1 subsequently completed; no integration decision needs reopening.

## Phase 1: single terminal vertical slice

- native macOS application
- Ghostty-backed terminal surface
- one interactive `zsh` session
- keyboard input and rendering
- resize propagation
- copy and paste
- clean process teardown

Exit: the app is usable as a basic single-window terminal and builds reliably.

**Status (2026-09-03):** complete. Human checks passed: `pwd`, multi-line output,
resize, copy/paste, selection highlight alignment, and close-window teardown.

## Phase 2: workspace

- new and close tab
- active terminal session
- independent working directories and processes
- basic restoration model
- split-pane architecture only after tabs are stable

Exit: multiple sessions remain isolated and lifecycle-safe.

**Status (2026-09-03):** complete. Human checks passed: independent tabs and
shells, hidden-tab process survival, close-tab teardown, and new-tab working
directory inheritance.

## Phase 3: shell semantics

- zsh shell integration
- investigate and implement OSC 133 boundaries
- capture command text, working directory, timestamps, and exit status
- persist structured `CommandRun` records in SQLite

Exit: commands are represented as structured records without parsing the rendered screen.

**Status (2026-09-03):** complete. Human checks passed: commands appear in
Window → Command History with working directory and exit status.

## Phase 4: local completion

- history-based prefix completion
- current-directory and repository-aware ranking
- filesystem path completion
- inline ghost text
- accept suggestion using Tab or Right Arrow

Exit: useful completion works offline and does not call an LLM per keystroke.

**Status (2026-09-03):** complete. Human checks passed: history and path ghost text,
Tab and Right Arrow accept, unmodified Tab still reaches zsh.

## Phase 5: next-command prediction

- record successful command transitions
- rank by repository, working directory, recency, and frequency
- display a distinct post-command suggestion

Exit: next-command prediction is separate from text completion and useful without AI.

**Status (2026-09-03):** implemented. Successful commands in a tab record
`previous → next` transitions in SQLite. An empty prompt shows a distinct accent
`→` suggestion in the sticky prompt footer (sibling under the grid, not an
overlay on scrollback), ranked by cwd, git root, frequency, and recency. Tab or
Right Arrow inserts the full next command. Prefix completion still owns typed
input on-grid while the live prompt is visible. Human check remaining.

## Phase 6: native AI runtime

- provider-neutral request and streaming event model
- application-owned agent runtime
- tool registry
- centralized permissions
- conversation storage
- native Ask panel
- one official API-backed provider

Exit: providers can be swapped without changing tool or permission behavior.

**Status (2026-09-04):** first Ask vertical slice implemented, per explicit user
request to start AI. Native Ask supports OpenAI API, Codex through its official
app-server, Anthropic API, Vercel AI Gateway, and Grok (xAI). Streaming and cancellation,
Keychain credentials, Codex ChatGPT sign-in, and isolated local conversations
are in the tree. Only explicit Ask messages are sent. Tool registry, tool permissions, and
autonomous execution remain deferred; Phase 6 as a whole is not complete.
See [`ai-ask.md`](ai-ask.md).

**Context slice (2026-09-04):** users can fetch and review a bounded static text
snapshot from a public HTTPS HTML/text page, attach it to one Ask message, and
inspect the saved source and text in conversation history. Pages are never
rendered or executed. Terminal output attachment remains future work.

**Inline routing slice (2026-09-04, catch-all 2026-09-05):** a local classifier
marks conversational text and unresolved commands at a ready zsh prompt and
routes them to Ask inside the same terminal tab. Cmd+Return forces shell
submission, `/agent ` forces AI, and shell syntax stays with the shell.
Routing is disabled while a foreground command or interactive program owns
input. This slice does not add tools or autonomous execution.

**Command approval slice (2026-09-04):** providers can propose one validated,
single-line zsh command through Sora's provider-independent response envelope.
The inline panel shows the purpose and exact command, and requires an explicit
Dismiss or Run decision. Approval is persisted before the command is submitted
to the current Ghostty terminal. No provider can execute directly, and command
output is not yet returned to the model.

## Phase 7: goal-oriented Agent harness

**Current baseline (2026-09-11):** multiple providers, bounded command execution,
webpage results, approval modes, malformed-action repair, and reusable Programs
are implemented. The earlier Phase 6 entries describe historical slices, not the
current absence of tools. H1–H3 now gate completion, track recovery, and enforce task-level budgets.
H6 raises Agent command deadlines to five minutes within the task budget.
H5 keeps Agent work alive across tab selection and restores conversations
as reviewable checkpoints after relaunch.

Target: understand the requested outcome, act within granted permissions, inspect
results, change approach when needed, verify completion, and involve the user
only for a concrete decision, permission, missing input, or exhausted limit.
Explanatory questions must still receive ordinary answers without unwanted work.

- [x] **H1 — Explicit goals and a completion gate.** Distinguish explanation from
  execution requests; retain the original goal and testable success criteria.
  A prose response cannot silently finish an execution task. Continue toward
  unmet criteria or report a specific waiting/paused state. Reuse existing tools,
  permission modes, and limits. Add scripted-provider regression tests for early
  advice, false completion, valid completion, ordinary questions, and Stop.
  Completed 2026-09-12: 278 tests and a live native printf/verification check;
  see [harness verification](verification-agent-harness.md).
- [x] **H2 — Result-driven recovery and progress tracking.** Retain attempts,
  observed failures, and what an alternative will change. Feed command errors,
  timeouts, empty/truncated results, and failed verification back into the loop.
  Detect equivalent retries and stalled plans; use bounded recovery, with no
  replays of side effects whose outcome is unknown. Depends on H1.
  Completed 2026-09-12: 284 tests, including repeated failure, timeout, launch
  failure, cycles, and uncertain-write replay checks; see [verification](verification-agent-harness.md).
- [x] **H3 — Task budgets and resumable checkpoints.** Replace the fixed
  per-message action ceiling with visible task-level action/time limits and
  request/token accounting where available. Continue through soft checkpoints
  while useful work and budget remain. Hard limits pause with saved progress
  and an explicit extension action; a new message does not silently reset them.
  Depends on H2; checkpoint durability is completed in H5.
  Completed 2026-09-12: 287 tests; default 24 actions, 80 requests, 15 active
  minutes, estimated tokens, saved checkpoints and explicit extension.
  See [verification](verification-agent-harness.md).
- [x] **H4 — Typed tools and precise permissions.** Introduce an internal tool
  registry and result model for bounded file reads/search, filesystem inspection,
  Git inspection, shell execution, and webpage fetches. Keep provider schemas in
  adapters. Show actual capabilities and current permissions to the model;
  authorize necessary writes explicitly and retain valid grants without asking
  again for the same approved action. Goal persistence does not widen access.
  Depends on H1; land one tool at a time.
  Completed 2026-09-12: 292 tests, five native inspection tools, exact-read
  grants/revocation, and a live file-read task reaching verified completion.
  Shell writes continue to use exact command approval. See [verification](verification-agent-harness.md).
- [x] **H5 — Durable tasks independent of tab selection.** Persist goal, evidence,
  attempts, pending decisions, budgets, and transcript by task/tab/provider.
  Switching tabs or hiding Agent does not cancel work. Restore tasks as reviewable
  checkpoints after relaunch without automatically replaying commands. Covers
  T05; use one implementation and one verification record. Depends on H1–H3.
  Completed 2026-09-12: 297 tests, isolated tab runtimes, versioned private
  checkpoints and bounded working context; live tab-switch/relaunch verified.
  See [verification](verification-agent-harness.md).
- [x] **H6 — Manage long-running commands.** Add task-owned process handles,
  incremental output, polling/backoff, deadlines, and cancellation. Distinguish
  a slow healthy process from a failure and from missing interactive input.
  Preserve the user's terminal ownership. Full REPL/TUI control is a later,
  separately scoped extension. Depends on H3–H5.
  Completed 2026-09-12: 299 tests, live bounded output, task-owned process
  snapshots, polling backoff, five-minute command deadlines and Stop.
  Native output disclosure and cancellation verified; see [verification](verification-agent-harness.md).
- [x] **H7 — Goal progress and focused human handoffs.** Show the goal, current
  action, concise progress, verification, and exact reason for waiting. Add
  Stop/Resume, steering, approval cards, and questions that say what was tried
  and what input unlocks progress. No routine “shall I continue?” prompts.
  Build on H1/H5; integrate U01 for transcript visibility.
  Completed 2026-09-12: 302 tests, queued steering, stale-action retirement,
  and a live update reaching completion without extra commands. See [verification](verification-agent-harness.md).
- [x] **H8 — Task-completion evaluation suite.** Extend H1's deterministic tests
  into realistic local fixtures and controlled same-model comparisons. Measure
  verified completion, premature endings, unnecessary interventions, recovery,
  cost/latency, and permission violations. Gate each later slice on its relevant
  scenarios; evaluations are part of development, not a final cleanup phase.
  Completed 2026-09-12: 304 tests, paired live fixture runner and recorded
  same-model pilot. See [evaluation method/results](agent-evaluation.md);
  the small sample does not establish a general completion rate or Warp ranking.

Exit: supported execution tasks reach evidenced completion or an accurate,
actionable waiting/paused state. The Agent recovers from ordinary failures,
preserves work, respects Stop and permissions, and improves measured completion
without hiding extra cost or unsafe actions.

## Phase 8: terminal features and UX backlog

These are incremental additions to the completed terminal foundation. Original
ROI order is retained for tracking; the harness is the current overall priority. Effort
is an initial estimate for a focused implementation plus verification:
**S = 1–3 engineering days; M = 4–7 days; L = multiple weeks.** Re-estimate when
an issue is picked up. These estimates are judgments, not measured delivery dates.

- [x] **T01 — Fuzzy command-history search (S–M).** Add a keyboard-first picker
  with This tab / This folder / All history scopes, highlighted matches, and
  insert-for-editing. Keep Up/Down tab isolation and draft restoration intact.
  Done when older commands are discoverable without remembering their prefix.
  Completed 2026-09-12: 306 tests, native Control-R picker, Unicode highlights,
  scope filters and insert-only behavior; Escape/draft and global insertion
  verified in the native app. See [terminal feature verification](verification-terminal-features.md).
- [x] **T02 — Command palette (S–M).** Search actions, sessions, settings, saved
  commands, and shortcuts from one entry point. Respect disabled actions and
  preserve terminal drafts/focus on dismissal. Expose existing capabilities first.
  Completed 2026-09-12: native ⌘⇧P palette, real menu validation/shortcuts,
  session switching and saved command insertion. Build and 306 tests passed;
  native action, disabled-action and draft checks recorded in [verification](verification-terminal-features.md).
- [x] **T03 — Ask Agent about selected output (S–M).** Attach a block or selected
  text to an editable question with a bounded context preview and removal control.
  Send only on explicit submission; preserve terminal selection and draft.
  Done when a failed command can be investigated without manual copy/paste.
  Completed 2026-09-12: 16 KB explicit attachments, editable question, preview
  and removal, provider-neutral persistence; 309 tests plus native selection,
  block, focus and draft-preservation checks. See [verification](verification-terminal-features.md).
- [x] **T04 — Automatic long-command completion alerts (S).** Use command finish
  events and a configurable duration threshold to notify for ordinary background
  commands. Retain existing notification preferences, focus suppression, origin
  navigation, and rate limits. Do not require the program to emit OSC/BEL.
  - [x] Implemented 2026-09-12: duration settings, ordinary completion hook,
    focus recheck and preserved failure badges; build and 310 tests passed.
  - [x] macOS permission and native background delivery: the user enabled
    notifications for the isolated Applications copy. A 35-second command
    finished while another tab remained selected; its badge and successful
    system delivery were confirmed. The stale permission-error display was fixed.
  - [x] Native notification click-through verified 2026-09-12: the user confirmed
    success, and native inspection showed Notification Fixture selected instead
    of Notification Observer. macOS recorded banner presentation; display-sharing
    suppression is an OS setting, so the human check used Notification Center.
    Updated verification build retained permission after replacement/relaunch;
    Debug/358 tests and arm64 Release passed.
    See [verification](verification-terminal-features.md).
- [x] **T05 — Durable Agent conversations and uninterrupted tab switching (M–L).**
  Tracked implementation: H5. Done when conversations restore after relaunch and
  changing tabs leaves the originating task running; canceled tasks stay stopped.
  Completed with H5 on 2026-09-12; see [verification](verification-agent-harness.md).
- [x] **T06 — Global show/hide shortcut (S).** Bring Sora forward from another app
  and restore previous focus when hidden. Verify multiple windows, displays, and
  Spaces. A dedicated drop-down window is a later sub-slice.
  - [x] Implemented 2026-09-12: opt-in native ⌃⌥S registration, conflict/status
    feedback, last terminal window and previous app restoration. Debug build
    and 310 tests pass; disabled/enabled startup and registration checked.
  - [x] Physical global-key show/hide and previous-app return verified 2026-09-12
    by the user while multiple terminal windows were open. The isolated copy's
    shortcut setting was restored to off after the check.
  - [x] User confirmed both other-Space and other-display show/hide and return
    checks pass on 2026-09-12. Window/tab identities, selection, split layout
    and the original draft remained unchanged.
  - [x] Resize clarification recorded 2026-09-12: the user may have manually
    moved/resized the window. Its 980×620 → 965×949 change is therefore an
    inconclusive frame comparison, not an established shortcut regression.
    Completion relies on the user's explicit functional passes; the precise
    cause of the resize is unproven. The test shortcut is back off and the
    resulting layout was preserved. See [verification](verification-terminal-features.md).
- [x] **T07 — Session-management polish (S–M).** Drag to reorder, double-click to
  rename, hover close controls, and distinguish running/finished/failed states.
  Retain keyboard alternatives, persistence, and running-task close warnings.
  - [x] Implemented rename, close controls, activity states, keyboard movement,
    and reorder logic. Native rename/close/status checks and persistence pass.
  - [x] Verified 2026-09-12: drag in both directions across two restored windows,
    repeated after relaunch without diagnostics; identity, selection, and split
    state remain intact. Debug build and 321 tests pass. See
    [terminal verification](verification-terminal-features.md).
- [x] **T08 — Saved commands from the terminal (M).** Save and name a command from
  a block/history, discover it through the palette, and insert it for editing.
  Reuse the local Programs investment where appropriate; add named parameter
  inputs as a follow-up. Reuse works with Agent disabled and spends no tokens.
  Completed 2026-09-12: block/history save and review, duplicate protection,
  palette insertion, Cancel/draft preservation, and relaunch verified; Debug build
  and 322 tests pass. See [terminal verification](verification-terminal-features.md).
- [x] **T09 — Richer completion menus (M–L).** Start with Git branches, package
  scripts, common flags, and descriptions. Provide a selectable native menu,
  preserve shell completion fallback, and verify aliases, quoting, large repos,
  stale results, and typing responsiveness. Avoid a large CLI catalog up front.
  Completed 2026-09-12: native branches/scripts/flags, descriptions, keyboard and
  mouse selection, escaped insertion and shell fallback; Debug build and 328
  tests pass. See [terminal verification](verification-terminal-features.md).
- [x] **T10 — Appearance and shortcut customization (M).** Add font-family choice,
  coordinated light/dark themes, compact spacing, and editable app shortcuts.
  Detect shortcut conflicts, offer reset, persist choices, and keep native chrome,
  sticky input, headers, and terminal rendering visually consistent.
  - [x] Appearance slice: live font choice, light/dark/system themes, compact
    spacing and reset; native split/relaunch/wrapped-input checks, GhosttyKit
    rebuild, Debug build and 332 tests passed. See [verification](verification-terminal-features.md).
  - [x] Editable app shortcuts, conflict detection, reset and native recording/
    relaunch checks passed. Final Debug/arm64 Release builds and 335 tests passed
    on 2026-09-12. See [verification](verification-terminal-features.md).
- [x] **T11 — Named project layouts (M).** Save/reopen named sets of folders, tabs,
  and panes alongside last-workspace restoration. Start with layout and directory
  state; handle missing folders explicitly. Startup commands need a separate
  reviewed slice and must not be inferred from archived output. Completed
  2026-09-12: native save/open/rename/delete, relaunch, fresh-session isolation,
  missing-folder Cancel/Home/picker checks; Debug build and 339 tests pass.
  See [terminal verification](verification-terminal-features.md).
- [x] **T12 — Complete split-pane controls (M–L).** Add split-below, keyboard pane
  focus, maximize/restore, and then nested splits. Preserve independent sessions,
  draft/focus state, resize behavior, close warnings, and layout restoration.
  Completed 2026-09-12: bounded nested layouts, four-way keyboard focus,
  maximize/restore, pane-local close and persisted ratios; native relaunch,
  saved-template and running-command checks passed with Debug build/344 tests.
  See [terminal verification](verification-terminal-features.md).
- [x] **T13 — Advanced block navigation and filtering (M–L).** Add bookmarks,
  search within a selected block, and filtering output to matching lines as
  separate slices. Define bookmark lifetime and verify live output, reflow,
  selection, restored archives, and explicit filter reset with Ghostty owning
  terminal state.
  - [x] Bookmarks: durable saved output copies, native library, source-tab
    navigation, duplicate/size/capacity handling, and explicit deletion. Completed
    2026-09-12 with native close/relaunch checks and 348 passing tests. See
    [verification](verification-terminal-features.md).
  - [x] Search within the selected block and U04 match/scope polish.
  - [x] Read-only matching-line filter with an explicit reset. Completed
    2026-09-12: native live-output, reflow, selected-text, restored-block and
    draft/focus checks; Debug build/352 tests and arm64 Release build passed.
- [x] **T14 — Rich behavior over SSH and other shells (L).** Extend semantic
  command boundaries, prompt context, and applicable completion beyond local
  zsh. Ordinary SSH already runs in the terminal; this item is rich integration.
  Publish a shell/remote capability matrix and verify clean fallback, disconnects,
  nested shells, remote paths, and absence of local/remote context confusion.
  - [x] Explicit remote context and safe native-input fallback.
  - [x] Optional Bash/zsh setup and portable SSH scripts with a capability matrix.
  - [x] Native connection/disconnect, nested-shell and remote-path verification.
  Completed 2026-09-12: Bash 3.2/5.2 checks, exported adapters over loopback SSH,
  remote zsh completion, Unicode paths, local/remote isolation and restored
  remote output; Debug build/358 tests and arm64 Release build passed. See
  [capability matrix](shell-integration.md) and [verification](verification-terminal-features.md).

Additional UX details from the comparison, to ship with the related feature or
as their own small slice:

- [x] **U01 — Agent response visibility.** Follow new output only while the reader
  is at the bottom; otherwise offer “New response ↓”. Keep reading position on
  expansion and older-message loading. Re-run the long-transcript stress fixture;
  prior layout churn makes this more than a cosmetic scrolling change. Links H7.
  Completed 2026-09-12: native follow observer, unread control, and the full
  302-message/240-update fixture. Existing bulk-layout warnings remain recorded
  in [architecture](architecture.md); this does not claim they are fixed.
- [x] **U02 — Compact chrome.** Reduce repeated Agent entry points and repeated
  directory/branch labels while retaining useful context and accessible controls.
  Verify narrow windows and splits. Links T10, but can ship independently.
  Completed 2026-09-12: duplicate controls removed; single/split, sidebar-hidden,
  720 px window, pane context and Agent/terminal navigation checked. Debug build
  and 335 tests pass; see [verification](verification-terminal-features.md).
- [x] **U03 — Accept one completion word.** Add partial acceptance alongside
  whole-suggestion acceptance, with discoverable shortcuts and correct quoting,
  Unicode, cursor position, and shell keybinding behavior. Links T09.
  Completed 2026-09-12: Option–Right, contextual hints, quoted-word parsing and
  native insertion/cursor fallback verified; Debug build and 330 tests pass.
  See [terminal verification](verification-terminal-features.md).
- [x] **U04 — Output-search polish.** Prefill from selected text, show current
  match position as well as total matches, and expose Terminal / Selected block
  scope. Verified focus, Escape, match navigation, and restored output with T13
  on 2026-09-12. See [terminal verification](verification-terminal-features.md).

Comparison references, checked 2026-09-11: Warp's
[command search](https://docs.warp.dev/terminal/entry/command-search),
[command palette](https://docs.warp.dev/terminal/command-palette),
[block actions](https://docs.warp.dev/terminal/blocks/block-actions),
[completions](https://docs.warp.dev/terminal/command-completions/completions),
[notifications](https://docs.warp.dev/terminal/more-features/notifications/),
[global hotkey](https://docs.warp.dev/terminal/windows/global-hotkey),
[workflows](https://docs.warp.dev/knowledge-and-collaboration/warp-drive/workflows/),
[launch configurations](https://docs.warp.dev/terminal/sessions/launch-configurations),
and [feature overview](https://www.warp.dev/all-features).
These are behavioral references, not dependencies or source to copy.

## Explicit non-goals for early phases

- cross-platform UI
- account system
- cloud sync
- collaboration
- hosted backend
- extension marketplace
- unofficial or scraped provider authentication
- AI calls on every keystroke

Full IDE/LSP integration, repository-wide indexing, MCP orchestration, and
multi-agent orchestration are deferred beyond this backlog. Reconsider them
only after the single-agent harness has measured completion improvements.

## Historical delivery notes

**Shareable CI zip (2026-09-05):** GitHub Actions (`Release zip`) builds an
ad-hoc Apple Silicon Release zip on `v*` tags or manual dispatch. Not notarized;
Gatekeeper requires right-click Open / `xattr -cr`. Paid Developer ID stays
deferred until public distribution matters. Sparkle 2.9.6 checks once per launch
and installs EdDSA-signed updates from the latest GitHub Release; the first
Sparkle-capable version still requires a manual install.

**Persistent agent slice (2026-09-05):** supersedes the earlier autonomous-execution
restriction for bounded native agent tasks. Agent mode stays open, captures command
results, and continues automatically for routine read-only listings. Other commands
require approval. Six commands per turn, 60 seconds per command, bounded output,
and Stop apply. Interactive commands and persistent shell-state changes remain open.
