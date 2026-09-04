# Sora

> Working name. Public naming and trademark clearance are not complete.

Sora is a macOS-first terminal that combines a strong native terminal experience with local command intelligence and an optional built-in AI agent.

The product must remain fully useful when AI is disabled. The intended progression is:

1. Great terminal
2. Smart terminal
3. AI-assisted terminal
4. Agentic development environment

## Initial stack

- Swift
- SwiftUI with AppKit where necessary
- Xcode
- `libghostty` (GhosttyKit / libghostty-internal) for terminal emulation and rendering
- SQLite for local structured history and workspace state
- macOS Keychain for secrets when provider support is added

Do not introduce Electron, Tauri, Flutter, Qt, a webview UI, or a separate Rust core during V0.

## V0 goal

Prove the native terminal foundation with the smallest useful vertical slice:

- launch a native macOS app
- embed a Ghostty-backed terminal surface
- start the user's `zsh`
- accept keyboard input
- render terminal output
- resize correctly
- support copy and paste
- manage terminal lifecycle cleanly
- build and run reliably from Xcode

AI, accounts, sync, cloud services, and polished styling are out of scope for V0. Local history completion (Phase 4) is in.

## Build and run

Requirements:

- macOS 13+ to run (building current Ghostty `main` needs Xcode 26 and the macOS 26 SDK)
- [Zig 0.16.x](https://ziglang.org/download/) (`brew install zig`)
- Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain` if `xcrun -sdk macosx metal --version` fails)

```sh
# 1. Build GhosttyKit and terminfo (clones Ghostty at the pinned commit)
./Scripts/build-ghosttykit.sh

# 2. Build the app
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' build

# 3. Tests (do not link libghostty; serial to avoid duplicate xctest workers)
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO test
```

The first launch starts a login `zsh` in a single window. Cmd+T opens a new tab; Cmd+W closes the current tab. The app is unsandboxed and ad-hoc signed for local use. Launch creates `~/.hushlogin` if missing so `login(1)` does not print the last-login banner.

Ghostty is pinned to commit `c81f0b26871c7fbbe2fc35549fdad1f64ed29094`. See [`docs/libghostty-integration.md`](docs/libghostty-integration.md).

## Documents

- [`CURSOR_HANDOFF.md`](CURSOR_HANDOFF.md): first prompt and stopping point for Cursor
- [`AGENTS.md`](AGENTS.md): persistent rules for coding agents
- [`docs/architecture.md`](docs/architecture.md): target architecture and boundaries
- [`docs/roadmap.md`](docs/roadmap.md): phased delivery plan
- [`docs/libghostty-integration.md`](docs/libghostty-integration.md): integration research and decision checklist
- [`docs/licensing.md`](docs/licensing.md): dependency and reference-project constraints
- [`docs/naming.md`](docs/naming.md): working-name status

Open **Window → Command History** after running a command to confirm structured history. Type a command prefix to see ghost text; Tab or Right Arrow accepts it. After a successful `git status` then `git push`, run `git status` again and look for italic `→ git push` on the empty prompt.

## Current status

Phase 5 next-command prediction is in the tree. Session chrome uses a native split view, 18pt type, and Ghostty macOS glass. AI is not implemented.
