# Roadmap

## Phase 0: integration decision

- inspect current Ghostty and Ghostling sources
- confirm supported `libghostty` embedding path
- document build, API, rendering, lifecycle, and licensing constraints
- create a short decision record

Exit: a concrete integration path with no unresolved foundational ownership question.

**Status (2026-09-03):** complete. PTY/shell ownership belongs to GhosttyKit
(`ghostty_surface_new`). `libghostty-vt` / Ghostling is rejected for V0.
Details: [`docs/libghostty-integration.md`](libghostty-integration.md).
Waiting on human approval before Phase 1 code.

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

**Inline routing slice (2026-09-04):** a conservative local classifier marks
clear conversational text at a ready zsh prompt and routes it to Ask inside the
same terminal tab. Cmd+Return forces shell submission, `/agent ` forces AI, and
ambiguous input remains with the shell. Routing is disabled while a foreground
command or interactive program owns input. This slice does not add tools or
autonomous execution.

**Command approval slice (2026-09-04):** providers can propose one validated,
single-line zsh command through Sora's provider-independent response envelope.
The inline panel shows the purpose and exact command, and requires an explicit
Dismiss or Run decision. Approval is persisted before the command is submitted
to the current Ghostty terminal. No provider can execute directly, and command
output is not yet returned to the model.

## Phase 7: agent mode and provider expansion

- multi-step agent loop
- terminal, filesystem, and Git tools
- approval UI
- interruption and recovery
- additional official providers
- investigate subscription-backed authentication only where sanctioned and maintainable

Exit: agents can perform bounded work with visible actions and consistent permissions.

## Explicit non-goals for early phases

- cross-platform UI
- account system
- cloud sync
- collaboration
- hosted backend
- extension marketplace
- unofficial or scraped provider authentication
- AI calls on every keystroke
