# Select all terminal input

At a ready shell prompt, Cmd+A and Edit > Select All select the native input
buffer, including newlines and wrapped text. Predictions are not input. While
a foreground program owns the terminal, the existing Ghostty Select All action
continues to apply.

Cmd+C copies the selected original text. Typing, pasting, Delete, and Cmd+X
replace or remove a fully selected buffer through the existing ZLE reuse widget;
none of those operations submits the command. Partial mouse selections retain
their existing copy-only behavior. Navigation clears the visual selection.

Validation: Debug build and all 266 tests passed. Manual checks in the updated
app covered multiline Cmd+A highlighting, copy with preserved newlines, typing
and paste replacement, and Delete. The prior welcome-panel change was also
built and visually checked in this session.

## Mouse selection and window movement

Window-background dragging is disabled; the title bar remains the window-drag
area. This lets content views receive drags for selection rather than moving
the window. Manually verified partial selection in terminal input, terminal
output, and the Agent composer after relaunch. The Agent test draft was cleared
without sending it. Debug build and all 266 tests passed.
