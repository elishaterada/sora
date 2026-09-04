# libghostty Integration

## Status

Phase 0 research complete against Ghostty `main` at commit
[`c81f0b26871c7fbbe2fc35549fdad1f64ed29094`](https://github.com/ghostty-org/ghostty/commit/c81f0b26871c7fbbe2fc35549fdad1f64ed29094)
(2026-09-03) and Ghostling
[`ghostty-org/ghostling`](https://github.com/ghostty-org/ghostling).

**Selected path:** embed Ghostty's macOS library `GhosttyKit` (also called
`libghostty-internal`) as a static XCFramework. That library owns VT state,
Metal rendering, PTY, and shell launch. Sora hosts a native `NSView` and
forwards window, input, clipboard, and lifecycle events.

Do not use `libghostty-vt` for the V0 terminal. That library is VT parsing and
render-state only. Using it would require Sora to own a PTY and a renderer,
which violates the product contract.

## Decision record

1. **Inspected revision:** Ghostty `main` @ `c81f0b26871c7fbbe2fc35549fdad1f64ed29094`; Ghostty version string in `build.zig.zon` is `1.3.2-dev`. Ghostling `main` README and `main.c` inspected the same day.
2. **Selected embedding approach:** `GhosttyKit.xcframework` produced by `zig build -Demit-xcframework=true`, linked into a Swift/AppKit host. Import as `GhosttyKit` via the upstream module map.
3. **Build commands:** see [Build and packaging](#build-and-packaging).
4. **Produced artifacts:** `macos/GhosttyKit.xcframework` containing `libghostty-internal.a`, `include/ghostty.h`, and `include/module.modulemap`. Runtime resources: `zig-out/share/terminfo` (required) and optionally `zig-out/share/ghostty/shell-integration`.
5. **Swift bridge shape:** one process-wide `ghostty_app_t`; one `ghostty_surface_t` per terminal view; a plain `NSView` whose `layer` is owned by libghostty; SwiftUI wraps that view with `NSViewRepresentable`.
6. **Lifecycle sequence:** see [Lifecycle](#lifecycle).
7. **Rejected alternatives:** see [Rejected alternatives](#rejected-alternatives).
8. **Known instability:** `include/ghostty.h` is documented as internal and macOS-app-specific. Signatures can change without a versioned API. Pin the Ghostty commit and treat upgrades as explicit work.
9. **Smallest next implementation step:** Phase 1 vertical slice described at the end of this file. No product code until that plan is approved.

## Two Ghostty libraries

Ghostty currently ships two different C surfaces. Mixing them up is the main
integration trap.

| Product | Header | What it does | What the host must provide |
| --- | --- | --- | --- |
| `libghostty-vt` | [`include/ghostty/*.h`](https://github.com/ghostty-org/ghostty/tree/main/include/ghostty) | VT parse, terminal state, keyboard/mouse encoding, render-state snapshots | PTY, process, renderer, windowing |
| `libghostty-internal` / GhosttyKit | [`include/ghostty.h`](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h) | Full embedder used by the Ghostty macOS app: PTY, shell, Metal, input, clipboard callbacks | Native view, event loop, OS clipboard, window chrome |

Official sources:

- Ghostty README: [`libghostty-vt` is the public portable library; Ghostling is the complete example](https://github.com/ghostty-org/ghostty)
- [`include/ghostty.h`](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h) header comment: this file is the internal embedder API; "the only consumer of this API is the macOS app"
- Mitchell Hashimoto, [Libghostty Is Coming](https://mitchellh.com/writing/libghostty-is-coming): the macOS app already consumes this internal C API; commercial products already embed it; a cleaner public API is still in progress
- Ghostling README: Ghostling uses **libghostty-vt**, Raylib for windowing/rendering, and host-owned `forkpty()`

Sora needs a working terminal, not a VT parser. That means GhosttyKit.

## Evidence that the required APIs exist

All symbols below are declared in
[`include/ghostty.h`](https://github.com/ghostty-org/ghostty/blob/c81f0b26871c7fbbe2fc35549fdad1f64ed29094/include/ghostty.h)
at the inspected commit.

### Process and app

- `ghostty_init(uintptr_t argc, char** argv)`
- `ghostty_config_new` / `ghostty_config_load_default_files` / `ghostty_config_finalize` / `ghostty_config_free`
- `ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t)`
- `ghostty_app_tick` / `ghostty_app_free` / `ghostty_app_set_focus`

### Surface, rendering, PTY

- `ghostty_surface_config_new` returns `ghostty_surface_config_s` with:
  - `platform_tag = GHOSTTY_PLATFORM_MACOS`
  - `platform.macos.nsview` (`void*` to an `NSView`)
  - `scale_factor`, `font_size`
  - `working_directory`, `command` (NULL = default shell)
  - `env_vars`, `initial_input`, `wait_after_command`
- `ghostty_surface_new` / `ghostty_surface_free`
- `ghostty_surface_draw` / `ghostty_surface_refresh`
- `ghostty_surface_set_size` / `ghostty_surface_set_content_scale` / `ghostty_surface_set_focus` / `ghostty_surface_set_occlusion`
- `ghostty_surface_foreground_pid` / `ghostty_surface_tty_name` / `ghostty_surface_process_exited` / `ghostty_surface_request_close`

`ghostty_surface_new` is the PTY/shell start. Ghostty's own AppKit surface
initializer comments that creating the surface "will also initialize all the
terminal IO"
([`SurfaceView_AppKit.swift`](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift)).
The Zig embedder maps `command` onto Ghostty's shell config in
[`src/apprt/embedded.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/apprt/embedded.zig).
If `command` is null, Ghostty launches the configured default shell.

### Input and clipboard

- `ghostty_surface_key` / `ghostty_surface_text` / `ghostty_surface_preedit`
- `ghostty_surface_mouse_button` / `ghostty_surface_mouse_pos` / `ghostty_surface_mouse_scroll`
- `ghostty_surface_has_selection` / `ghostty_surface_read_selection` / `ghostty_surface_read_text`
- Runtime callbacks on `ghostty_runtime_config_s`: `wakeup_cb`, `action_cb`, `read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`, `close_surface_cb`
- `ghostty_surface_complete_clipboard_request` / `ghostty_surface_deny_clipboard_request`

Ghostty's macOS app wires those callbacks in
[`Ghostty.App.swift`](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Ghostty/Ghostty.App.swift).
`wakeup_cb` may run off the main thread; the app hops to the main queue and
calls `ghostty_app_tick`.

## Build and packaging

### Toolchain

Ghostty `main` currently requires:

- Zig `0.16.0` (`minimum_zig_version` in [`build.zig.zon`](https://github.com/ghostty-org/ghostty/blob/main/build.zig.zon))
- Xcode 26 and the macOS 26 SDK to *build* Ghostty from `main` ([`HACKING.md`](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md))
- Metal Toolchain (`xcodebuild -downloadComponent Metal` if `xcrun metal` is missing)

The resulting library's deployment target is macOS 13.0
([`Config.osVersionMin`](https://github.com/ghostty-org/ghostty/blob/main/src/build/Config.zig)
and `MACOSX_DEPLOYMENT_TARGET = 13.0` in
[`macos/Ghostty.xcodeproj/project.pbxproj`](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.xcodeproj/project.pbxproj)).
Architectures: native arm64, or universal arm64 + x86_64 via
`GhosttyLib.initMacOSUniversal`.

Local machine at research time: macOS 26.6.2, Xcode 26.6, Metal present, **Zig not installed**. Phase 1 must install Zig 0.16.0 first. Xcode 26.4+ has had Zig linking issues; Ghostty documents a 0.15.x workaround. 0.16.0 + Xcode 26.6 must be verified during the first GhosttyKit build.

### Commands that produce GhosttyKit

From a Ghostty checkout:

```sh
# Native host architecture (fastest for local Phase 1)
zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast

# Universal macOS (arm64 + x86_64), slower
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

Default macOS behavior when `app_runtime` is unset also emits the XCFramework
because [`Config.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/build/Config.zig)
turns `emit_xcframework` on for Darwin library builds. The explicit `-Demit-xcframework=true`
flag is the documented switch.

Do **not** use `zig build -Demit-lib-vt`. That produces `ghostty-vt.xcframework`,
which is the VT-only library demonstrated by
[`example/swift-vt-xcframework`](https://github.com/ghostty-org/ghostty/tree/main/example/swift-vt-xcframework).

### Artifacts

| Artifact | Path | Notes |
| --- | --- | --- |
| XCFramework | `macos/GhosttyKit.xcframework` | Static `libghostty-internal.a` plus headers |
| Header | `include/ghostty.h` | Copied into the XCFramework |
| Module map | `include/module.modulemap` | `module GhosttyKit { umbrella header "ghostty.h" }` |
| Combined archive name | `ghostty-internal.a` / `libghostty-internal.a` | Dependencies are combined into one archive ([`GhosttyLib.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/build/GhosttyLib.zig)) |
| Terminfo | `zig-out/share/terminfo` | Must land in the app bundle |
| Shell integration | `src/shell-integration` → `zig-out/share/ghostty/shell-integration` | Optional for V0 |

Swift import: `import GhosttyKit`.

### Linking

Ghostty's Xcode project links GhosttyKit and adds `-lstdc++`
([`project.pbxproj` `OTHER_LDFLAGS`](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.xcodeproj/project.pbxproj)).
Phase 1 should start with that exact flag. If the linker then reports missing
symbols, add Apple frameworks that Ghostty's Metal/font stack uses: `Metal`,
`MetalKit`, `CoreText`, `CoreGraphics`, `QuartzCore`, `IOSurface`, `Carbon`,
`AppKit`. Prefer the minimal set that actually links.

The static archive bundles compiler-rt and its C/Zig dependencies (FreeType,
HarfBuzz, and others). Consumers link one XCFramework, not fifteen `.a` files.

### Runtime resources

libghostty locates resources by walking up from the executable until it finds
`Contents/Resources/terminfo/78/xterm-ghostty`, then uses
`Contents/Resources/ghostty` as the resource root
([`src/os/resourcesdir.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/os/resourcesdir.zig)).
Release builds also honor `GHOSTTY_RESOURCES_DIR`.

Phase 1 must copy at least:

```text
Sora.app/Contents/Resources/terminfo/78/xterm-ghostty
```

Shell integration and themes can wait unless the default shell looks broken
without them.

## Rendering integration

- Host: a plain `NSView`. Do not install a `CAMetalLayer` and do not override
  `makeBackingLayer`. libghostty creates its own layer (IOSurface/Metal) and
  assigns it onto the view. Installing a competing Metal layer leaves Ghostty
  rendering into an orphaned layer (blank terminal).
- Pass the view pointer as `ghostty_platform_macos_s.nsview`.
- Keep the view's frame non-zero before `ghostty_surface_new` so layer bounds
  exist (Ghostty's SurfaceView uses a default 800×600 frame for this reason).
- Some embedders wait until `viewDidMoveToWindow()` because the Metal surface
  wants a window. Phase 1 should create the surface after the view is in a
  window if `ghostty_surface_new` fails earlier.
- Size: `ghostty_surface_set_size(surface, width_px, height_px)` from
  `NSView.bounds` in points converted to backing pixels, or pixel size matching
  Ghostty's own host. Also call `ghostty_surface_set_content_scale` when the
  backing scale changes.
- Redraw: libghostty drives GPU rendering; the host calls `ghostty_app_tick`
  when `wakeup_cb` fires, and `ghostty_surface_set_occlusion` when the window
  is hidden.

## PTY and process ownership

**libghostty-internal owns the PTY and launches the shell.**

Sora must not call `forkpty`, `posix_spawn` a shell, or write a PTY bridge for
the V0 path.

- Default shell: leave `ghostty_surface_config_s.command` null.
- Explicit zsh: set `command` to `/bin/zsh` only if the default shell is wrong
  during verification. Prefer Ghostty's default first so login-shell behavior
  stays upstream.
- Working directory: `working_directory`, or null for home.
- Child exit: `ghostty_surface_process_exited`, `close_surface_cb`, and
  `ghostty_surface_foreground_pid`.
- Teardown: `ghostty_surface_request_close` then `ghostty_surface_free`. Confirm
  no orphaned shell with `pgrep`/`ps` after the window closes.

Contrast: Ghostling's [`pty_spawn`](https://github.com/ghostty-org/ghostling/blob/main/main.c)
calls `forkpty` + `execl(shell)` and feeds bytes through
`ghostty_terminal_vt_write`. That is the VT-only model. Do not copy it.

## Lifecycle

```text
ghostty_init(argc, argv)                  # once per process
ghostty_config_new()
# Phase 1: do not load ~/.config/ghostty unless we explicitly want it
ghostty_config_finalize(config)
ghostty_app_new(&runtime, config)         # process-wide

# After NSView is in a window:
surf = ghostty_surface_config_new()
surf.platform_tag = GHOSTTY_PLATFORM_MACOS
surf.platform.macos.nsview = view
surf.scale_factor = window.backingScaleFactor
surface = ghostty_surface_new(app, &surf) # PTY + shell start

loop:
  wakeup_cb -> DispatchQueue.main.async { ghostty_app_tick(app) }
  resize -> ghostty_surface_set_size / set_content_scale
  keys -> ghostty_surface_key / ghostty_surface_text
  copy  -> ghostty_surface_read_selection + NSPasteboard
  paste -> ghostty_surface_text or clipboard complete callback

on close:
  ghostty_surface_request_close(surface)
  ghostty_surface_free(surface)
  ghostty_app_free(app)
  ghostty_config_free(config)
```

Threading: create and tick the app on the main thread. `wakeup_cb` is the
cross-thread hop. Do not introduce a Swift actor that wraps every C call until
the vertical slice works; keep a `@MainActor` runtime object instead.

## Input and clipboard for V0

Minimum:

1. Make the `NSView` first responder.
2. Forward keyDown/flagsChanged through `ghostty_surface_key` and insert text
   through `ghostty_surface_text` (study Ghostty's AppKit surface; do not copy
   the file).
3. Copy: if `ghostty_surface_has_selection`, `ghostty_surface_read_selection`
   onto `NSPasteboard.general`.
4. Paste: read `NSPasteboard` string and `ghostty_surface_text`.
5. Implement the three clipboard runtime callbacks with the smallest behavior
   that unblocks OSC 52 and ordinary paste. Confirm prompts can be "allow" for
   V0 only if documented as a known issue.

IME can be incomplete in V0 if ASCII input works. Record it as a known issue
rather than porting Ghostty's full `NSTextInputClient` implementation on day one.

## Distribution and signing

- GhosttyKit is a static archive inside an XCFramework, so it folds into the
  Sora binary. No extra dylib to notarize.
- The app still needs a stable bundle ID, hardened runtime decisions, and
  entitlements. A sandboxed app cannot spawn a useful user shell without
  temporary-exception entitlements. **Phase 1 should ship unsigned, unsandboxed,
  locally run.** Signing/notarization is later.
- Include Ghostty's MIT copyright and a third-party notices file before any
  public binary. See [`docs/licensing.md`](licensing.md).

## Rejected alternatives

| Option | Why rejected |
| --- | --- |
| `libghostty-vt` + Sora renderer | Builds a terminal emulator. Forbidden. |
| Ghostling as a starting point | Raylib UI, host-owned PTY, C, not Swift/AppKit. |
| Official `example/swift-vt-xcframework` | VT-only; prints screen text; no PTY, no Metal. |
| Community `lakr233/libghostty-spm` | Extra third-party wrapper over the same unstable API. Keep the dependency list minimal. |
| Copying Ghostty `SurfaceView_AppKit.swift` | MIT-legal, but thousands of lines of Ghostty-app UI (tabs, splits, inspector). Study it; write a thin host. |
| Electron / Tauri / Flutter / Qt / webview | Forbidden by `AGENTS.md`. |
| Application-owned Zig or Rust FFI | Forbidden for V0. Linking Ghostty's Zig-built C library is allowed. |

## Known issues and human-review decisions

- Internal API: pin commit `c81f0b26871c7fbbe2fc35549fdad1f64ed29094` unless a
  human chooses a Ghostty 1.3.x release instead. 1.3.x may still need Zig
  0.15.2; current `main` needs 0.16.0.
- Whether Phase 1 should call `ghostty_config_load_default_files()` (picks up
  the user's Ghostty config) or start from a blank config. Recommendation:
  **blank config** so Sora behavior is reproducible.
- App sandbox: off for V0.
- **NSApp is nil during SwiftUI `App.init()`.** Do not read `NSApp.isActive` until the window appears.
- **SwiftUI `WindowGroup` first responder is often the hosting view, not `GhosttySurfaceView`.** Do not rely on Edit menu `copy:` / `paste:` reaching the NSView. Copy uses `ghostty_surface_read_selection` onto `NSPasteboard.general`; paste uses `ghostty_surface_text`. SwiftUI `.commands` call those methods on the active surface.
- **`ghostty_surface_mouse_pos` is top-left origin.** Convert AppKit view points with `y = height - y` or selection highlights land on the opposite edge of the view.
- **Do not destroy a surface when its `NSView` leaves the window.** Tab switching and SwiftUI churn must not reap the PTY. Destroy only when the tab or window is closed.
- **Keep hidden tab views in the hierarchy** (`isHidden` + `ghostty_surface_set_occlusion`) rather than using a SwiftUI `TabView` that recreates `NSViewRepresentable` contents.
- **OSC 133 D becomes `GHOSTTY_ACTION_COMMAND_FINISHED`** with exit code and duration only. Ghostty's zsh integration also writes the command to OSC 2 in preexec; capture that title when the finish action arrives. Do not scrape the screen.
- Linking GhosttyKit requires `Carbon` (TIS keyboard APIs) in addition to Metal, CoreText, QuartzCore, and IOSurface.
- Xcode 26.6 + Zig 0.16.0 produced a working native `GhosttyKit.xcframework` after `xcodebuild -downloadComponent MetalToolchain`.
- Full third-party license inventory of the static archive is not complete.
  FreeType, HarfBuzz, fontconfig, JetBrains Mono, and others are pulled in by
  Ghostty's build. Release-gate item, not a Phase 1 code blocker.

## Smallest Phase 1 implementation plan

1. Install Zig 0.16.0 and confirm `zig version`.
2. Add Ghostty as a git submodule at the pinned commit.
3. Build `GhosttyKit.xcframework` and copy terminfo into the app resources.
4. Create a native macOS SwiftUI app with one window.
5. Add a thin AppKit `NSView` + `NSViewRepresentable`.
6. Implement `GhosttyRuntime` (`init` / config / app / tick / clipboard stubs).
7. Create one surface after the view is in a window; leave `command` null.
8. Forward keyboard, resize, copy, paste, and teardown.
9. Add tests only for Swift configuration/lifecycle helpers that do not need a
   windowed Metal surface.
10. Stop. Do not add tabs, shell integration, or AI.
