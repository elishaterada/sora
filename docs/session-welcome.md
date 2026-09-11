# New-session welcome

New terminal panes show a native welcome panel above the sticky input with
Sora's supported shortcuts: history, multiline entry, Agent, and forced shell
execution. The panel is outside libghostty and never becomes command output.
It disappears on the first submitted command or when Agent opens. Restored
panes with a history archive do not show it. “Don’t show again” persists the
terminal.showsSessionWelcome preference. Short panes temporarily omit the panel
to preserve usable terminal space.

Validation: Debug build and all 265 XCTest tests passed. In the running app,
verified a restored session had no welcome, a new tab showed the panel, typing
kept it visible, and executing pwd dismissed it. Visually checked spacing and
shortcut readability. Persistent dismissal was not toggled during manual QA
to preserve the user's preference.
