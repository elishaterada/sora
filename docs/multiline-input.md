# Multiline command input

The native prompt grows with wrapped shell input to at most half the terminal
pane, retaining its 112-point minimum for context and keyboard hints in small
panes. Overflow scrolls within the input using the mouse wheel or trackpad.
Scrolling does not alter the ZLE cursor; editing or moving the cursor reveals
its row again. History previews retain their existing fixed-height behavior.

Long input previously disappeared because Ghostty's OSC parser is bounded and
its window-title delivery buffer accepts fewer than 256 bytes. Shell reports
now split encoded snapshots into 40-character pieces, keeping even UTF-8 text
below the delivery limit. A per-surface assembler publishes only complete,
ordered snapshots. Short reports retain the previous wire format. Both live
input and preexec command reports use this transport so history keeps newlines.
No Ghostty code or dependency was modified. Existing shells need a new session
to load the updated shell integration.

Validation: Debug build, full XCTest suite, and direct zsh execution reporting
500 multiline export statements, checking reconstructed content and every
message's byte limit. The user verified the fix in the relaunched Debug app
on September 11, 2026.
