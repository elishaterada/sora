# Tab-switch latency — September 16, 2026

## Cause and change

The sidebar attached a double-tap gesture before its single-tap gesture.
SwiftUI waited for the double-click recognition interval before selecting a
tab. This introduced about 351 ms of delay even with no terminal or persistence
work involved.

`WorkspaceTabBar` now recognizes double-click renaming simultaneously with
single-click selection. The first click selects immediately; a second click
still opens Rename Tab. Accessibility selection and drag-to-reorder retain
their existing actions.

This does not change terminal memory use. `WorkspaceController` retains live
Ghostty surfaces, and `WorkspaceHostView` retains their pane views. Hidden tabs
continue receiving terminal output while their renderers are marked occluded.
Switching reveals the live surface; it does not reload an archived transcript.
Archives are for session restoration and durability, not ordinary tab switching.

## Measurement

A temporary native AppKit/SwiftUI harness hosted the exact two gesture modifiers
extracted from `WorkspaceTabBar.swift`, with lightweight selection/rename
callbacks. A local mouse-up monitor timestamped actual pointer events, and the
selection callback recorded elapsed time. Native UI automation supplied clicks.
The check asserted selection within 50 ms and, after a double-click, exactly one
rename callback.

| Gesture recognition | Before | After |
| --- | --- | --- |
| Three separate single clicks | 351.60, 351.39, 351.14 ms | 0.56, 0.54, 0.48 ms |
| Double click | Not part of baseline measurement | Selection 0.69/0.53 ms; one rename |

The baseline failed the 50 ms budget; the changed gesture passed. These measure
mouse-up to the selection callback, not click-to-photon latency. The isolated
harness ruled out disk saving and terminal activation as causes of this delay.
It does not rule out additional costs in larger workspaces. No unit test was
added for gesture arbitration: that behavior requires SwiftUI and real pointer
events, rather than the workspace model's selection methods.

## Verification

```sh
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/sora-tab-switch-build \
  -parallel-testing-enabled NO test
```

The app built and all 384 tests passed. An isolated development bundle was used
for full-app checks without replacing the installed app or its saved workspace:

- Pointer-clicked between two terminal tabs.
- Ran `for i in {1..8}; do printf 'TAB_FRESH_%s\n' $i; sleep 1; done`,
  switched away while it ran, and verified all eight output lines on return.
- Double-clicked the other tab, verified the rename dialog, and canceled it.
- Dragged the second tab above the first and verified the reordered sidebar.

To reproduce the original delay, compare pointer selection with keyboard tab
selection before this change. Accessibility action invocation alone bypasses
the conflicting pointer gestures and cannot validate this fix.

Next issue: measure end-to-end tab display latency with many tabs and sustained
output, including the remaining synchronous workspace metadata persistence.
