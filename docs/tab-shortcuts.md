# Numbered tab shortcuts

Command–1 through Command–9 select the corresponding tab in the current sidebar
order. Reordering changes the numbers. Command–9 means the ninth tab, not the
last tab. Missing positions do nothing; Command–0 retains terminal behavior.
Extra Shift, Option, or Control modifiers are not numbered-tab shortcuts.

The Tabs menu owns the shortcuts, including when Agent input has focus.
`GhosttySurfaceView` also routes numbered shortcuts to the workspace explicitly:
otherwise an unavailable menu item can fall through to Ghostty's Command–9
last-tab binding. The first nine tabs receive hints; later tabs remain available
through pointer selection and Next/Previous Tab.

Holding Command alone for one second shows ⌘1…⌘9 in the sidebar's existing
close-button slots, without shifting the rows. Releasing Command, pressing a
key, adding another modifier, opening a sheet, losing window focus, or switching
apps hides the labels. After using a shortcut, release and hold Command again
to reveal them. The observer is local to the app and active sidebar window;
it passes every event through and removes its monitor, timer, and notification
observers when detached. No accessibility permission or global listener is used.
Collapsed sidebars have no labels.

## Verification — September 16, 2026

```sh
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/sora-tab-switch-build \
  -parallel-testing-enabled NO test
```

Build and all 388 tests passed. New tests cover the one-second threshold,
release, repeated modifier reports, shortcut cancellation, other modifiers,
focus-reset behavior, valid number combinations, and indexing after reordering.

Native checks in an isolated development bundle verified Command–1/2/3 among
three tabs, Command–2 from the Agent text field, and Command–9 leaving the second
tab selected when only three tabs exist. The last check initially exposed the
Ghostty fallback and passed after explicit workspace routing was added.

The user also verified the physical Command-hold interaction in the isolated
build and confirmed that it works.

Next issue: make numbered shortcut hints discoverable with the sidebar collapsed.
