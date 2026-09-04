# Agent Instructions

These rules apply to every coding agent working in this repository.

## Product contract

- Build a native macOS terminal application.
- Use Swift, SwiftUI, AppKit where needed, and Xcode.
- Use `libghostty` rather than building a terminal emulator from scratch.
- The terminal must work fully when AI is disabled.
- Keep Warp, Vercel `fx`, and other products as references only. They are not runtime dependencies.
- Sora is a working name. Do not spend time on branding or assume trademark clearance.

## Scope discipline

- Complete one phase or vertical slice at a time.
- Phase 0 through Phase 4 are complete. Do not reopen them unless a regression appears.
- Phase 6 Ask AI is authorized: ship one optional native Ask slice at a time.
- Accounts, sync, hosted backends, and autonomous command execution remain out of scope.
- Do not add speculative abstractions for future cross-platform support.
- Do not introduce Rust, Zig, UniFFI, or another application-owned FFI layer during V0.
- Native interoperability required by `libghostty` is allowed.

## Architecture rules

- Keep terminal rendering and PTY/session lifecycle outside SwiftUI view logic.
- Prefer small, cohesive Swift types.
- Avoid global mutable state and singleton-heavy design.
- Separate UI, session orchestration, infrastructure, and persistence.
- Use Swift concurrency when it makes lifecycle and ownership clearer.
- Provider-specific AI code must eventually live under `Providers/`.
- Future agent tools and permissions must use internal abstractions, not provider-owned schemas.
- Secrets must use macOS Keychain, never SQLite or source-controlled files.

## Engineering rules

- Preserve a buildable Xcode project after each task.
- Keep dependencies minimal and document why each dependency exists.
- Prefer Apple-native APIs when practical.
- Add tests for logic that can be exercised without UI automation.
- Do not hide failures with placeholder implementations or silent fallbacks.
- Record consequential decisions in `docs/`.
- Update documentation when an implementation invalidates an assumption.

## Licensing rules

- Verify dependency licenses before copying or adapting code.
- Do not copy AGPL-licensed Warp code into this repository.
- Preserve required notices for Ghostty or other embedded dependencies.
- Distinguish studying behavior and architecture from copying implementation.

## Completion standard

Before declaring a task complete:

1. Build the relevant scheme.
2. Run available tests.
3. Exercise the changed path manually when possible.
4. Summarize files changed and commands run.
5. List known issues and decisions requiring human review.
6. Recommend exactly one next issue.

