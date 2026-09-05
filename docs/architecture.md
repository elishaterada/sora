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
- settings and keyboard shortcuts

### Terminal

- GhosttyKit bridge (`ghostty_app_t`, `ghostty_surface_t`)
- AppKit `NSView` host; libghostty owns the Metal layer
- surface lifecycle and teardown
- keyboard and pointer forwarding
- resize and backing-scale propagation
- clipboard: Cmd+C/V and Edit menu copy/paste via `ghostty_surface_read_selection` / `ghostty_surface_text`; OSC 52 via Ghostty runtime callbacks plus `NSPasteboard`
- session chrome: flush two-column `HStack` (sidebar | terminal). Transparent titlebar with `fullSizeContentView` so close/minimize/zoom sit in the sidebar next to the collapse control. Collapsing the sidebar hides that column; the traffic lights, sidebar toggle, session title, path, and new-tab control move into a thin terminal header. Do not use `.toolbar(.hidden, for: .windowToolbar)` — that hides the window buttons. No `NavigationSplitView` (Tahoe draws that as floating rounded cards). Window frost is a square `NSGlassEffectView` behind both columns.
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
- Inline suggestions use a fixed prompt origin captured before the first keystroke. The tracked ASCII buffer determines the suffix column, so text and position change together without following intermediate PTY cursor redraws or running a polling timer. Untracked, non-ASCII, and wrapped input suppresses the overlay rather than guessing its position.
- overlay resets on Enter, Esc, arrows (except accept), Ctrl-C/U/A/E/K/W, Option, mouse down, and multiline paste. zsh Tab-complete and history recall desync the buffer until the next prompt.
- next-command prediction on an empty prompt after a successful command, shown as accent `→` text in the sticky prompt footer under the grid (not as an overlay on scrollback). Esc or Up/Down/Left dismisses it until the next successful command. Prefix ghost text stays on-grid only while the live prompt is visible; scrolling away hides the overlay and mirrors the line in the footer.

### Agent, Providers, and Tools

The first Phase 6 slice uses `AskSession` for main-actor conversation state and
request cancellation, `AIProvider`/`AIRequest`/`AIEvent` for provider-neutral text
streaming, and `AIBackend` for the five available providers. `HTTPAIProvider`
shares URLSession transport across OpenAI Responses, Anthropic Messages, and
Vercel and xAI Chat Completions; adapters translate their distinct event schemas.
`CodexProvider` uses `CodexConnection` to run the installed official app-server
over stdio with an ephemeral, text-only thread. `CodexLogin` owns sign-in setup.
`AskView` is the inline agent continuation inside the active terminal tab
(AI → Ask Sora or prompt routing). Ask fills the tab; Escape returns to the
terminal. Each tab keeps its own in-memory agent thread, and a terminal→agent
handoff starts a fresh conversation for that tab. Storage is injected;
credentials use Keychain. Switching providers cancels outstanding work and
restores that provider's draft, model, and per-tab history. No tool interface is
exposed in this slice.
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
