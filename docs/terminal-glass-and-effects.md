# Terminal glass and optional effects

The terminal shares the existing full-window native glass material (NSGlassEffectView on macOS 26, NSVisualEffectView on older macOS). Both dark and light themes use an 18% terminal background, a clear pane backing, and a 20% input wash. macOS Reduce Transparency supplies an opaque backing beneath the same content and updates live.

The existing Ghostty semantic-block patch now draws low-alpha neutral and pink error washes; empty rows no longer paint a second background. Explicit ANSI backgrounds use 82% opacity, retaining their color with a little glass showing through. Selections, inverse-video cells, and block dividers keep their existing rendering. Pinned command headers use a native behind-window material with the same translucent neutral/error washes as blocks, so desktop frost remains visible without scrolled glyphs colliding with the header label. This change requires rebuilding GhosttyKit with `scripts/build-ghosttykit.sh`; changing SwiftUI alone does not update block fills.

Settings → Terminal → Playful effects offers four independently saved, initially disabled options:

- Ambient glow: a static teal radial wash with a short typing response.
- Shake window while typing: a damped rotational impact around the content’s center. Return/keypad Enter has a much stronger, longer rebound that interrupts ordinary typing and retains priority for 240 ms. The native window frame never moves; only the presentation layer rotates, including in maximized/full-screen windows. Pauses during dragging and stops when disabled, focus is lost, or Reduce Motion is enabled.
- Typing sounds: ten original synthesized mechanical-keyboard-inspired profiles with adjustable volume and an explicit Preview Sound button. Four subtle tap variations and two deeper Return variations are preloaded per selected profile; a bounded voice pool allows natural overlap without queuing sounds. Uses NSSound and the system audio output, with no downloaded recordings or new dependencies.
- Return-key light pulse: a brief light response when pressing Return; it does not imply command success.

Effects observe local key events in a terminal pane and return them unchanged. Shortcuts, navigation keys, and held-key repeats do not trigger effects. Feedback is rate-limited to prevent a backlog. Each window owns its monitor and animation state; disabling all effects removes its monitor. Reduce Motion suppresses animated light and window movement while retaining the optional static glow and separately controlled sound. Turn Off All Effects leaves glass and semantic highlighting intact.

## Verification (2026-09-12)

- `./scripts/build-ghosttykit.sh` — rebuilt the native framework successfully. Reverse application check confirms the vendored checkout matches the committed patch.
- `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test` — passed all 363 tests. Includes typing-feedback filtering and the light-theme opacity regression check.
- Built a separate preview using `-derivedDataPath /tmp/sora-glass-preview PRODUCT_BUNDLE_IDENTIFIER=dev.sora.glass-preview build`.
- Exercised successful and failed shell commands, explicit ANSI backgrounds, block selection/escape, live dark/light switching, each effect toggle, and Turn Off All Effects in that preview. Commands still run with all effects enabled. Optional glow appears across both areas.
- Sound and shake intensity need subjective human review. Accessibility behavior was inspected in code; the host's global accessibility settings were not changed. App-window captures do not establish wallpaper contrast under every desktop background. Existing unrelated Swift concurrency warnings remain.

Changed files: theme/preferences, window frost, terminal pane backing, Ghostty theme and semantic renderer patch, the new window-owned TerminalEffects view, Settings, Xcode source registration, pinned-header commentary, input/appearance tests, and this document. No new dependencies.

### Sticky header and ANSI refinement

Removed the remaining solid pinned-header colors. StickyCommandHeaderView now uses a behind-window NSVisualEffectView plus the block's translucent tint; CommandHeaderStyle also softens explicit ANSI backgrounds in native labels while keeping inverse text and fills opaque. The renderer patch applies 209/255 opacity to explicit ANSI backgrounds after selection and inverse-video handling.

Rebuilt GhosttyKit and the isolated preview. `xcodebuild ... clean build test` refreshed Xcode's cached framework path after the framework rebuild; the final `xcodebuild ... build test` passed all 364 tests after retaining concrete foreground RGB values for VT reset consistency. Manually checked scrolling with ANSI output and a fresh 18-line failed command: the pinned header remains legible with a translucent pink wash, matching the error region. No new dependencies or known blockers; the exact opacity remains a visual preference for human review.


### Rotational typing impacts

Replaced the frame-origin shake loop: AppKit can normalize screen coordinates, so exact comparison against a fractional requested position is not a reliable restoration guard. The replacement never calls window positioning APIs. TypingImpact animates only the root content layer's sublayerTransform around a fixed center, replaces an interrupted animation from its visible angle, and ends at the unchanged model transform. Ordinary keys settle in 360 ms; Return hits over four times harder and settles in 650 ms. Return bypasses the ordinary feedback throttle and cannot be immediately swallowed by the next character. No snapshot overlay, private window APIs, or delayed restoration task is involved. The outer macOS frame stays stationary.

Verification: `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test` passed all 366 tests. The added AppKit regression exercises 100 impacts on a window with fractional starting coordinates, checks unchanged window geometry and model transforms, checks Return priority over subsequent typing, and verifies center invariance and stronger bidirectional recoil. Rebuilt the isolated preview and exercised typing and Return with the effect enabled; command execution still works. The animation affects rendered content inside the stationary native border; perceived impact strength remains a human preference.


### Ten typing sound profiles

Settings → Terminal → Playful effects now calls the option Typing sounds. Keyboard sound offers Silent Linear, Soft Tactile, Deep Thock, Creamy Pop, Crisp Clack, Clicky Switch, Heavy Switch, Hollow Case, Metal Case, and Spring Switch. Selection and volume are saved; existing sound-enabled and volume preferences are retained. Missing/unknown profile identifiers resolve to Crisp Clack. Preview Sound is explicit and available while typing sounds are off; changing the selection does not play audio automatically.

TypingSound creates original PCM waveforms with different body resonances, filtered transients, delayed tactile clicks and case/spring rings. These are inspired sound designs, not recordings or exact reproductions of branded switches. Envelopes start/end at silence and peaks are bounded. TypingSoundPlayer prepares the small voice pool only on profile changes, reuses it on the input path, and stops previous voices when switching. Playback/setup errors appear in the preview UI and are logged for terminal playback.

Verification: `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test` passed all 368 tests. New checks decode all ten profiles and Return variants using NSSound, validate distinct sample data, silent endpoints, unclipped peaks, per-key variation, profile fallback, and loading/switching the voice pool. The isolated preview build passed. Manually verified all ten menu choices, selected Deep Thock, invoked Preview Sound with typing sounds both enabled and disabled, then exercised terminal input and Return. No playback error appeared. Auditory realism and preferred timbre still require human listening; no branded-switch recording claims are made.


### Varied impact choreography

The public macOS window surface has no rotation transform for the native border/shadow, so Sora animates its rendered content inside the stationary system frame. Eight patterns now vary rotation strength/sign, horizontal/vertical recoil, spring frequency, and damping. A shuffled cycle uses every pattern once before reshuffling and prevents an immediate repeat at a cycle boundary. Return retains its stronger amplitude and interruption priority. Retriggering inherits both visible rotation and displacement, and every pattern settles to the unchanged model transform. Accessibility and stop behavior remain unchanged.

Eight-pattern verification: `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test` passed all 368 tests. Tests exercise four shuffled cycles, all eight distinct trajectories, no adjacent repeats, bounded displacement, exact settling, inherited pose continuity and stronger Return variants. The fractional-window-position regression still passes. The isolated preview build passed, and manual typing/Return execution completed successfully. Impact strength and feel remain for human review; native border/shadow rotation remains unavailable through the supported window APIs.


### Impact strength

Settings → Terminal → Playful effects adds a saved Impact strength slider from 25% to 200%, in 5% steps. Existing installations default to 100%, preserving the previous eight-pattern choreography. Rotation and directional displacement scale together; Return keeps its relative strength and priority. Invalid/nonfinite stored values are safely normalized. Reset Strength restores 100% without affecting other effects. The explicit Preview Return Impact button animates only the Settings window’s content and works without enabling typing shake; Reduce Motion disables the preview. Changing strength does not play an animation automatically and stops any in-flight terminal impact before using the new strength.

Strength-control verification: `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test` passed all 369 tests. The new test verifies clamping/nonfinite preferences and proportional rotation/displacement at 25%, 50%, 100%, and 200% for all eight patterns and both typing/Return variants, including exact settling. The isolated preview build passed. Manually adjusted 100% → 110% using two increments, invoked Preview Return Impact, and verified Reset Strength returns to 100%. Left the Settings preview at that default. No new known blockers; the native border remains stationary and impact feel is a user preference.

## Release 0.3.0 preflight

The exact release version passed all 369 tests with `xcodebuild ... build test`. `MARKETING_VERSION=0.3.0 CURRENT_PROJECT_VERSION=20 ./scripts/package-app.sh` built the Apple Silicon Release archive, including the current Ghostty renderer patch. The packaged app reports 0.3.0 / 20, `lipo -archs` reports arm64, and `codesign --verify --deep --strict` passes. The changelog extraction for 0.3.0 contains the user-facing glass, sound, impact, and accessibility highlights. Manual coverage is recorded above. Distribution remains ad-hoc signed and unnotarized as described in docs/releasing.md.
