# Cursor Handoff

Open this repository in Cursor, read all Markdown files, and follow `AGENTS.md` as the persistent project contract.

## Objective

Build the smallest reliable native macOS terminal vertical slice using Swift and `libghostty`.

Do not implement AI yet.

## First assignment

### Phase 0: focused research

1. Inspect the current Ghostty and Ghostling repositories.
2. Determine the best currently supported way to embed `libghostty` in a Swift macOS application.
3. Identify the required Ghostty build products, headers, module maps, linking configuration, initialization flow, and rendering host.
4. Confirm whether Ghostty owns the PTY/shell session or whether the host app must provide it.
5. Identify supported macOS deployment targets, architecture constraints, and required system frameworks.
6. Verify relevant licenses and attribution requirements.
7. Update:
   - `docs/libghostty-integration.md`
   - `docs/architecture.md`
   - `docs/licensing.md`

Time-box research. The goal is enough confidence to build a vertical slice, not exhaustive documentation.

### Phase 1: terminal vertical slice

1. Create a native Swift macOS application and Xcode project in this repository.
2. Embed the smallest viable Ghostty-backed terminal view.
3. Start the user's default shell, targeting `zsh` first.
4. Implement keyboard input and visible terminal output.
5. Propagate view-size changes to the terminal surface and PTY.
6. Add basic copy and paste.
7. Shut down the session cleanly when its view or window closes.
8. Add focused tests for non-UI lifecycle or configuration logic where practical.
9. Document exact build and run instructions in `README.md`.

## Constraints

- Native macOS only.
- No Electron, Tauri, Flutter, Qt, or webview interface.
- Do not build a terminal emulator.
- Do not introduce Rust for our own application logic.
- Do not implement tabs until the single-session vertical slice is reliable. **Phase 0–4 are complete. Phase 5 is next-command prediction.**
- Do not implement AI, providers, or agents until Phase 6.
- Do not copy code from Warp.
- Keep the implementation intentionally small and understandable.

## Required verification

Before stopping:

- Build successfully from Xcode or `xcodebuild`.
- Launch the app.
- Confirm an interactive shell appears.
- Run `pwd` and confirm output.
- Run a command that emits multiple lines.
- Resize the window and confirm correct reflow or terminal resize behavior.
- Verify copy and paste.
- Close the window and confirm there is no orphaned shell process.

If the environment prevents interactive verification, complete all safe build checks and state exactly what a human must test on a Mac.

## Stop condition

Stop after the current approved phase is working or after documenting a concrete blocker. Phase 0–4 are complete. Phase 5 is next-command prediction. Do not continue into AI until that phase is approved.

Provide a final summary containing:

- architecture used
- files added or changed
- build and run instructions
- verification performed
- known issues
- human-review decisions
- the single recommended next issue

