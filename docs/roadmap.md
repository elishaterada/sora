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

## Phase 6: native AI runtime

- provider-neutral request and streaming event model
- application-owned agent runtime
- tool registry
- centralized permissions
- conversation storage
- native Ask panel
- one official API-backed provider

Exit: providers can be swapped without changing tool or permission behavior.

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

