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
`Completion/`, and `Intelligence/`.

## Responsibilities

### Application

- app and scene lifecycle
- native windows and menus
- settings and keyboard shortcuts

### Terminal

- GhosttyKit bridge (`ghostty_app_t`, `ghostty_surface_t`)
- AppKit `NSView` host; libghostty owns the Metal layer
- surface lifecycle and teardown
- keyboard and pointer forwarding
- resize and backing-scale propagation
- clipboard: Cmd+C/V and Edit menu copy/paste via `ghostty_surface_read_selection` / `ghostty_surface_text`; OSC 52 via Ghostty runtime callbacks plus `NSPasteboard`
- session chrome: two-column `NavigationSplitView` (sidebar | terminal), compact toolbar, no inset cards. Sora hosts a flush `NSGlassEffectView` behind the grid because libghostty does not install liquid glass in the embedder.
- shell presentation: `~/.hushlogin` suppresses `login(1)` "Last login"; a Sora `ZDOTDIR` sources Ghostty's zsh integration, replaces the stock macOS `user@host` prompt, and colors the input line (command/flags/paths/strings) unless the user already has zsh-syntax-highlighting.

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
- overlay resets on Enter, Esc, arrows (except accept), Ctrl-C/U/A/E/K/W, Option, mouse down, and multiline paste. zsh Tab-complete and history recall desync the buffer until the next prompt.
- next-command prediction on an empty prompt after a successful command, shown as italic accent `→` ghost text, ranked by cwd, git root, frequency, and recency. Esc or Up/Down/Left dismisses it until the next successful command.

### Agent, Providers, and Tools

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

