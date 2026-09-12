# Terminal feature verification

## T01 — command history search (2026-09-12)

Control-R at an integrated, ready shell opens a native searchable sheet. Edit →
Search Command History provides a discoverable menu entry. Searches use the full
stored history, independently of the existing tab-only Up/Down prefix recall.
This tab, This folder, and All history scopes filter before ranking. Contiguous
matches rank above subsequences, then recency breaks ties. Matches preserve
Unicode character ranges. Results show the working folder, date and use count.

Search runs on a serial worker with a short debounce and stale-result rejection.
Queries and output counts are bounded; SQL parameters keep wildcard characters
literal. Older commands are not excluded by a recent-history cap. No search
keystroke changes the shell buffer. Return or Insert Command stages the selected
text through the existing ZLE replacement widget; a later Return executes it.
Escape restores terminal focus without changing the draft or cursor.

Validation:

- `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test`: 306 tests passed.
- Added coverage for scope isolation, older results, literal percent/underscore,
  accent folding in both directions, Unicode highlight ranges and ranking.
- Native check: ran `printf SORA_HISTORY_PICKER`, typed a separate unsent draft,
  searched `sorhspk`, and canceled. The original draft remained unchanged.
- Switched to All history, selected the highlighted match, and pressed Return.
  The command appeared at the ready prompt without executing.

Control-R continues to belong to foreground programs or shells without Sora's
editable-line integration. This picker introduces no AI requests or dependencies.

## T02 — command palette (2026-09-12)

View → Command Palette and Command-Shift-P open a native keyboard picker. It
searches the current menu titles, category paths and shortcut symbols, plus
sessions and the shared local Programs catalog. Menu actions use their actual
handlers and validate again after restoring focus. Disabled actions remain
visible with an explanation and cannot run. Saved programs insert their script
for editing only at an integrated ready prompt, independent of Agent settings.
The saved working directory is shown; insertion does not change directories.

Validation: the Debug build and all 306 tests passed. Native checks covered
Settings opening, creating a tab, switching back with Down/Return, a disabled
Undo action staying open on Return, and Escape preserving the terminal draft.
The terminal key-equivalent handler now lets Command-Shift-P reach the app menu.
Services menus are excluded from the palette; no external app action runs while
collecting or searching entries.

## T03 — ask about output (2026-09-12)

Command block actions, selected-text context menus and the Edit menu expose
Ask Agent About Output. The app captures a static UTF-8 excerpt of at most 16 KB,
with the command when available and the terminal folder at capture (which may
be different from the historical command's folder). It opens a focused editable
question, a disclosure preview and a removal button. Attaching does not send.

The attachment is provider-neutral untrusted reference data, not instructions,
execution evidence or permission. It survives conversation persistence after
Send. Pending attachments belong to the tab/provider's in-memory draft, stay
out of automatic Agent continuations, and can be sent after a running task
finishes or is stopped. Unsaved draft attachments are not restored after app quit.

Validation: Debug build and 309 tests passed. New cases cover UTF-8 bounds,
excerpt labeling, legacy decoding, each provider's request, tab isolation,
explicit Send and preserving the attachment when conversation saving fails.
Native checks used a harmless failed printf command and a partial text selection.
Both opened previews without sending; Remove kept the question; returning to the
terminal retained the selected block and the original shell draft. The deferred
composer focus fix was rebuilt and checked in the app.

## T04 — long-command completion alerts (2026-09-12)

Ordinary structured command-finish events now call the existing notification
controller after the configured duration. Default is 30 seconds; Settings offers
5 seconds through 5 minutes and a separate long-command toggle. The master
notification preference still applies. Titles distinguish success and failure;
body text identifies the command. The originating tab's finished/failed badge
is retained, and the existing click-through handler opens that session.

The five-second per-session throttle and focus suppression remain in effect.
Focus is checked again after asynchronous authorization and before foreground
presentation, so returning to the terminal suppresses a delayed banner.

Debug build and 310 tests passed, including duration boundaries, invalid stored
values, disabled notifications, foreground/background cases and throttling.
Native Settings changes and a background `sleep 6; false` with alerts disabled
confirmed the failure badge remains. Preferences were restored to enabled and
30 seconds. Native permission and click-through were initially pending; the
completed human-assisted verification is recorded below.

Final verification follow-up used the 358-test build. From
`/tmp/sora-verification-build/Build/Products/Debug/Sora.app`, Allow Notifications
returned “Notifications are not allowed for this application.” Native relaunch
did not change that result. The valid ad-hoc signature passed deep/strict
verification, but `usernoted` reported failure to find or validate the client.
Copying this same bundle to `~/Applications/Sora Verification.app` and launching
through the native app tool resolved client validation: `usernoted` identified
the installed path and recorded a permission alert presented for
`dev.sora.verification`. Thus this observation does not establish a signing
requirement or a production notification regression.

Computer Use then refused access to `com.apple.UserNotificationCenter` for safety
reasons. A human permission check was requested; banner delivery and origin-tab
navigation were deferred at that stage. The isolated copy is at the path above;
the installed production app was left running and unchanged. System evidence:
`/tmp/sora-t04-notification-system.log` and
`/tmp/sora-t04-installed-notification-system.log`. The verification preferences
were notifications on, long-command alerts on, threshold 30 seconds, and the
global shortcut off.

On resuming the check, macOS reported permission denied. The app opened its
notification settings, and the user enabled notifications there. Native System
Settings then showed Allow Notifications, Desktop and Notification Center on.
In an owned Notification Fixture tab, `sleep 35; printf 'SORA_NOTIFICATION_OK\n'`
completed successfully in 35.098 seconds while Notification Observer stayed
selected. The tab displayed Finished, and `usernoted` recorded successful delivery
for `dev.sora.verification`, including banner presentation. The same log records
interruption suppression with reason `display shared`, so the human interaction
used Notification Center. On 2026-09-12 the user confirmed click-through works;
native inspection independently showed Notification Fixture selected in its
original window, replacing the previously selected Notification Observer tab.
This verifies delivery and source navigation; it does not claim that Sora
overrides macOS's display-sharing suppression. Evidence:
`/tmp/sora-t04-authorized-delivery.log` and
`/tmp/sora-t04-fixture-workspace.json` (owned fixture identities).

The native permission transition exposed a stale error label: Settings correctly
changed to Allowed but retained the earlier authorization failure underneath.
`TerminalNotificationSettingsSection.refreshStatus()` now clears a resolved
error for authorized, provisional or ephemeral permission. Debug build and all
358 tests pass (`/tmp/sora-t04-final-check.log`). Apple Silicon Release and the
isolated native build also pass (`/tmp/sora-t04-release-build.log` and
`/tmp/sora-t04-native-build.log`); `git diff --check` passes. After click-through
passed, the owned two-tab fixture window was closed. The isolated Applications
copy was replaced with the final build and relaunched: Settings showed Allowed
without the stale error, and the original two windows/four tab identities and
literal `echo durable-draft` remained intact. Notifications stayed enabled with
the 30-second threshold. The installed production app was untouched.

## T06 — global show/hide shortcut (2026-09-12)

Settings offers an opt-in Control–Option–S binding through RegisterEventHotKey.
No event tap, Accessibility permission or keyboard monitoring is used. The app
owns registration and unregisters it when disabled or deallocated. A conflict
has visible error/status feedback. The last registered terminal window is shown
and deminiaturized; hiding returns to the app captured before showing. Window
positions and Spaces remain owned by macOS, following its activation preference.
With no terminal window remaining, the app opens a new one.

Build and 310 tests passed. Native launch testing found and fixed a synchronous
UserDefaults-notification deadlock during AppKit font initialization: callbacks
now schedule asynchronously, and initial registration waits for the main loop.
Disabled and enabled launches now succeed; Settings reports “Shortcut ready.”
Debug builds log actual toggle events for inspection, without terminal content.

Targeted automation keystrokes did not generate Carbon hotkey events, so a
physical-key check was requested. During the resumed human-assisted check, the
isolated Applications copy was enabled and Settings showed “Shortcut ready.”
The user confirmed Control–Option–S works for the requested show/hide and
previous-app return sequence on 2026-09-12, with multiple terminal windows open.
After replacing/relaunching the verification copy, Settings still reported
Shortcut ready. The verification preference was then restored to off; the
production app's preference was not changed.

The user subsequently confirmed availability of another Space and another
display, then reported Pass for each explicit check: focus another app there,
press Control–Option–S twice, observe Sora on its original Space/display and
return to the prior app without window movement or duplication.

Baseline comparison independently confirmed the same two window identities,
all four tab identities/names, directories, selection, split layout, and exact
unsubmitted `echo durable-draft`. One window's saved frame changed from
`{{209, 108}, {980, 620}}` to `{{547, 0}, {965, 949}}`; the other window's frame
was unchanged. The strict frame comparison therefore did not pass. On follow-up,
the user said they may have manually moved or resized the window. This makes
the comparison inconclusive: it cannot establish that the shortcut caused the
change, and the exact cause remains unproven. T06 is complete based on the user's
explicit Space/display functional passes, with this measurement limitation
retained rather than claiming identical window geometry across the whole test.
The shortcut code has no frame-setting call; the workspace's frame restore is
guarded to run once. Neither fact proves the source of the observed resize.

Evidence: `/tmp/sora-t06-spaces-before.json` and
`/tmp/sora-t06-spaces-after.json` (private local snapshots). The system-log query
in `/tmp/sora-t06-spaces-shortcut-events.log` returned no matching shortcut events,
so the physical activation evidence is the user's direct report. The verification
shortcut was restored to off, the resulting window layout was preserved, and
the installed production app was unchanged. No code changes were made during
these checks; the same build's 358 tests and Debug/Release builds had passed.

## T07 — session controls (2026-09-12)

Rows expose hover/selected close controls, double-click renaming, running,
finished, failed, and Agent-busy states. Cmd-Shift-R renames, Cmd-Option-Up/Down
reorders, and native close warnings cover active terminal or Agent tasks.
The drag gesture targets the nearest visible row within the session list.
Pure tests cover identity/order preservation and scrolled/drop geometry.

Native checks confirmed rename, running → failed status, the close warning and
Cancel path, keyboard movement, and restoration of tab names/IDs. Drag moved Beta
above Alpha in the single-window app. The subsequent multiwindow automation was
initially inconclusive; after reconnecting to the current native verification
build, diagnostics confirmed correct event delivery and row geometry. Both drag
directions passed with two restored windows. The check passed again after removing
diagnostics and relaunching. Selection and split pane identity were retained.
Debug builds and all 321 tests pass. See the separate
[durability verification](workspace-durability.md) for update/relaunch coverage.

## T08 — saved terminal commands (2026-09-12)

Command block actions, Command History row context menus, and the Ctrl-R picker
now offer Save Command. The shared native dialog reviews name, description,
script, and saved folder. It uses the existing private Programs catalog and reads
the latest catalog at Save time. Duplicate names (case/diacritic insensitive),
invalid input, full catalogs, and write errors remain visible without overwriting
another command. Cancel changes neither catalog nor the terminal's draft.

Saved commands appear in the command palette and insert for editing in the
current terminal. This also works while browsing command output: choosing a saved
command returns to input. A running process cannot receive the command through
this path. Saving and reuse do not invoke an Agent, generate executable files,
change directories, or execute the command. Programs remains available for
review/deletion with AI disabled. Named parameter inputs remain a follow-up.

Debug build and 322 tests passed. The added catalog test covers literal multiline
scripts, missing saved folders, fresh reads across two store instances, duplicate
names, invalid controls, and absence of generated executable files. Native checks
with AI disabled saved from Ctrl-R history and a command block, rejected a duplicate
name, cancelled a changed save draft, reopened the app, and reused through the
palette from both input and block browsing. SQLite confirmed only the original
fixture execution. The two test-only saved entries were removed afterward.

## T09 — contextual completion menus (2026-09-12)

Native Tab choices cover Git subcommands/local branches, npm/pnpm/yarn/bun `run`
scripts, and selected common flags with descriptions. One matching result inserts
for editing. Multiple results open a native menu with Up/Down, Return/Tab,
Escape and mouse selection. Edit → Show Command Completions opens the menu even
for one result. The menu never executes the chosen command.

Tests cover loose/packed refs, linked worktree common directories, macOS `/tmp`
URL aliases, duplicate refs, nearest-package lookup, quoted Unicode/metacharacter
names, invalid and oversized files, a 20,000-ref catalog, and a 1,000-request burst
that performs only the original and newest lookups. Read counts/sizes and menu
results are bounded. A path regression found during the native check now escapes
spaces/metacharacters and leaves complex quoted input to the shell.

Native checks with AI disabled used `/tmp/sora-t09-native-fixture`. Branch
Down/Return and script mouse selection inserted without execution; quoted script
names stayed literal. Flag descriptions, Escape preserving a draft, ordinary
typing dismissing the menu, a sole `--max-count=` match, and the explicit Shell
completion button were checked. Quoted paths used zsh completion. Aliases stayed
outside the new catalog. The final native build inserted `ls path\ example/` without execution.
The disposable window was closed; the original restored windows stayed intact.
Debug build and all 328 tests passed (`/tmp/sora-t09-final-check.log`); the
isolated native build passed (`/tmp/sora-t09-final-native-build.log`).
Commands: `xcodebuild ... build test` with parallel testing disabled and
`xcodebuild ... PRODUCT_BUNDLE_IDENTIFIER=dev.sora.verification build`.

Limitations: local branches only; package scripts use the nearest manifest, not
workspace expansion. Known executable names shadowed by shell aliases are not
introspected; use the menu's shell fallback. Slow external volumes cannot be
forcefully interrupted during an OS read, but no obsolete result reaches input
and the main thread remains free. No added dependencies or network access.

## U03 — accept one completion word (2026-09-12)

Option–Right accepts one word of a visible suggestion only while the shell owns
a ready prompt, the caret is at the end and the live line matches the tracked
suggestion. The hint advertises the shortcut only when a partial acceptance is
available. Edit/palette also exposes Accept Next Completion Word. Tab/Right
retain whole-suggestion acceptance. Without an eligible suggestion, Option–Right
passes to the shell unchanged.

`CompletionWord` preserves leading spacing, shell-quoted phrases, backslash
escapes, Unicode graphemes and combining marks. It declines multiline input,
command substitutions, incomplete quotes/escapes and shell expressions it cannot
safely divide. Repeated acceptance retains the remaining suggestion; edits
invalidate it. Two tests cover parsing and successive acceptance/invalidation.

Debug build and 330 tests passed (`/tmp/sora-u03-check.log`). The isolated native
build passed (`/tmp/sora-u03-native-build.log`). In the app, Option–Right inserted
`'%s\n'`, then a complete quoted phrase containing spaces, without executing the
command. Moving the caret to the start and pressing Option–Right retained zsh's
word movement, confirmed by inserting a character at the new caret. Unicode
joining/combining sequences were checked in pure tests; the native automation's
text entry omitted the emoji in its fixture. The disposable window was closed
without running the accepted draft.

## T10a — appearance controls (2026-09-12)

Settings → Terminal → Appearance offers installed monospaced fonts, Dark / Light /
System, compact spacing, the existing size slider and Restore Appearance Defaults.
The choices apply without restarting terminal sessions. Native checks changed
existing split panes to Light/Menlo/compact, quit and reopened the app, and confirmed
all three preferences in Settings with the original windows and split state intact.
A clean window showed successful and failed command blocks in light mode. The
28 pt maximum wrapped an editable draft over three lines with a visible caret;
Reset restored Dark/SF Mono/18 pt and normal spacing without executing that draft.

The native run caught and fixed early application initialization and light-chrome
contrast issues. Tests cover installed-font validation/config injection prevention,
font-family reset, full light palette, foreground/accent contrast, and wrapped-input
geometry. Debug build and 332 tests passed in
`/tmp/sora-t10-appearance-final-check.log`; the isolated native build passed in
`/tmp/sora-t10-appearance-final-native-build.log`. GhosttyKit rebuilt successfully
with the updated existing renderer patch (`/tmp/sora-t10-ghostty-final-build.log`).
The shell's future duration labels were subsequently switched to theme palette
colors; final resource/build verification is recorded with T10 completion.

The shortcut portion and final native checks are recorded in T10b below. Explicit RGB output from programs or old archives keeps its original
colors. Appearance changes do not reinterpret that output or restart commands.

## T10b — editable app shortcuts (2026-09-12)

Fifteen app actions now share a validated shortcut catalog: windows/tabs, rename
and reorder, split/single pane, search, palette, Agent and sidebar. Settings offers
recording, per-action reset and all-shortcuts reset. The palette reads actual menu
shortcuts, including readable arrow symbols; Agent/close hints update with edits.
Standard editing, numbered tab selection and terminal input remain reserved;
the opt-in global shortcut remains in its separate section.

Native checks rejected Command-C as reserved and Command-T as occupied by New
Tab, recorded Option-Command-P for the palette, cancelled recording with Escape,
and opened the palette with the new chord. After quitting/reopening, that chord
still worked and Settings showed its saved value. Restore All returned to
Shift-Command-P, which opened Settings through the palette again. These checks
did not execute terminal input or alter the original windows/drafts.

Final T10 verification also checked System appearance against the current dark
macOS appearance, light welcome/new-window input, theme-aware failure labels,
and Restore Appearance Defaults. The native check found and fixed a new-window
input-layer initialization mismatch. All verification preferences were returned
to defaults, and disposable windows were closed. Explicit program/archive RGB
colors retain their original values; automatic scheduled OS theme changes were
not simulated by changing the user's system settings.

Final commands/checks:
- `scripts/build-ghosttykit.sh` — passed, existing MIT-licensed patch rebuilt.
- `zsh -n Sora/Resources/zsh/command-blocks.zsh` — passed.
- `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test` — 335 tests passed (`/tmp/sora-t10-final-check.log`).
- Isolated Debug build with `PRODUCT_BUNDLE_IDENTIFIER=dev.sora.verification` — passed (`/tmp/sora-t10-final-native-build.log`).
- `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Release -destination 'platform=macOS,arch=arm64' ARCHS=arm64 build` — passed (`/tmp/sora-t10-release-build.log`).
- `git diff --check` — passed. No release was published.

## U02 — compact chrome (2026-09-12)

Removed the duplicate sidebar Agent button and the repeated directory/branch
chips from the window header. The header retains session identity, the Agent
entry point and sidebar-hidden navigation. Each terminal pane keeps its own
path/branch actions; Agent keeps its working context in its status bar.

Debug build and all 335 tests passed (`/tmp/sora-u02-check.log`); the isolated
native build passed (`/tmp/sora-u02-native-build.log`). Native checks covered
single/split windows, hiding the sidebar, resizing to 720 px, opening the path
menu, opening Agent with its retained shortcut, and Escape back to the terminal.
Controls remained reachable and context stayed local to the pane. No Agent
message was sent. The disposable two-pane window was closed; original windows
and the Beta draft remained intact.


## T11 — named project layouts (2026-09-12)

Native checks in the isolated verification app saved Backend/Frontend tabs with
different folders, a split and the second tab selected. Opening from the palette
restored that arrangement with empty input in both panes and no copied history.
Typing a new draft targeted the selected Frontend pane. The catalog and workspace
files confirmed disjoint session IDs for the source and reopened windows.

Renaming and quit/relaunch preserved the template. The source's unsubmitted draft
and the reopened window's separate draft both survived relaunch without running.
Moving the owned web fixture folder produced explicit recovery choices: Cancel
kept four existing windows; Home changed only the missing pane; the native folder
picker opened a new pane in the chosen moved folder. Neither recovery rewrote
the template. Deletion Cancel retained it; confirmed deletion removed only the
owned layout while its open windows remained. The test windows were then closed
and the fixture folder restored. The original Beta draft and installed app were
untouched.

Four tests cover fresh identities, missing-folder validation, independent catalog
merges, stale revisions, duplicates, permissions, backup recovery, original-byte
preservation and unsupported-version protection. Debug build and 339 tests
passed (`/tmp/sora-t11-check.log`); the isolated native build passed
(`/tmp/sora-t11-native-build.log`). A final replacement-path validation check was
added after the native run and included in the subsequent build/test run.
No startup command execution or production release is included.


## T12 — nested split controls (2026-09-12)

The native fixture created a stacked split, then split its lower pane side by
side. Each pane retained distinct output and an unsubmitted draft. A native
shortcut check caught and fixed Control-modified arrow recognition; all four
directional focus actions then moved editing to the expected adjacent pane.
Maximize/relaunch retained the selected pane and draft; Restore Pane Layout
revealed the same three sessions. Only the active input edge/caret is accented.

Both dividers responded to dragging and accessibility stepping. Quit/relaunch
preserved the original window/session UUIDs and non-default ratios
(0.5508517887563884 stacked, 0.45 side by side). Saving/opening the nested layout
restored its axes and pane order with disjoint new session IDs and empty drafts.
A bounded `sleep 60` fixture triggered the close warning; Cancel kept it running,
and Control-C stopped it. Closing that pane collapsed only its branch. A focus
refinement was then verified in the final build: closing the right pane selected
its lower-left sibling. Ghostty can also conservatively request confirmation for
a restored draft; that confirmation remains authoritative.

New Tab temporarily showed a single session; selecting the prior pane tab restored
its split. Return to Single Pane kept every tab. All owned fixture windows and the
saved test layout were removed; the original two windows/four tabs and Beta
draft remain. Multi-display placement was not changed during this check.

Pure tests cover nested non-overlapping geometry, directional focus, branch
collapse and neighbor selection, ratio clamping, malformed/oversized trees,
legacy migration, maximize serialization and fresh template identities. Final
Debug build and all 344 tests passed (`/tmp/sora-t12-final-check.log`); the isolated
native build passed (`/tmp/sora-t12-final-native-build.log`).

T12 also passed the arm64 Release build (`/tmp/sora-t12-release-build.log`) and
`git diff --check`. No release was published.


## T13a — durable block bookmarks (2026-09-12)

Native capture saved a known three-line block with indentation while preserving
an unsubmitted shell draft. Repeating Bookmark Block selected the existing copy.
Show Source Tab returned to block browsing without inserting or running input.
The read-only library displayed the saved text, including its visible duration
line. SQLite inspection confirmed the captured literal output.

The first native Command-W test exposed a cached-focus bug that closed the owned
test source behind the library. The bookmark survived, providing the closed-source
fixture. This was fixed before completion: actual key-window ownership now gates
workspace actions, and the library's close/find keys stay local. In the final
behavioral run, both Command-W and File → Close left all three terminal windows
intact, including the new fixture's exact draft; Command-F searched the library.
New Tab and Save Project Layout were unavailable from the utility window.

After quit/relaunch the saved copy remained readable; Show Source Tab explained
that its source had closed. Search clearing, deletion Cancel and confirmed deletion
worked. Only owned test records/windows were removed. Original verification
windows and the installed app were unaffected.

Four new tests cover literal/NUL/Unicode persistence, independent instances,
deduplication, deletion isolation, 0600 permissions, marked UTF-8 excerpts, capacity
without eviction, and protection of future/corrupt database bytes. Debug build
and all 348 tests passed (`/tmp/sora-t13-bookmarks-focus-check.log`); the isolated
native build passed (`/tmp/sora-t13-bookmarks-focus-native-build.log`). A final
empty-search wording improvement is included in the following final check.
Bookmarks contain saved copies, not live output or durable pointers into Ghostty.


## T13b/c and U04 — scoped output search and filtering (2026-09-12)

A disposable two-tab native fixture verified literal block search (two matches),
Return/Shift-Return navigation, Terminal scope including command text, selected
word prefill, zero matches, query clearing and explicit Show All Lines reset.
Filtering returned exactly the two matching output lines without changing the
source terminal. Refresh recaptured a snapshot while a bounded eight-line command
was running; native whole-terminal totals updated as new lines arrived.

The source's unsubmitted draft stayed exact through filtering, panel closing,
block browsing and quit/relaunch. Relaunch preserved both fixture session UUIDs,
selected tab, window frame and restored block output. Search still found the two
expected matches after reflow and at the terminal window's minimum width (701 px
in this check); the separate Find panel remained on screen. Command-W closed
only Find. The owned fixture window was removed, leaving the original two
windows/four tabs and Beta draft intact; the installed app was untouched.

Ghostty's last restored command block can include the passive “Previous session
ended · New shell” banner. The snapshot faithfully shows that visible text; it
does not infer a command result from it or remove potentially literal user text.

Four tests cover Unicode/UTF-16 ranges, literal matching, navigation, verbatim
line filtering, empty/no-match behavior, clipping/caps and stale/canceled worker
results. Final Debug build and all 352 tests passed
(`/tmp/sora-t13-search-final-check.log`), as did the isolated native build
(`/tmp/sora-t13-search-final-native-build.log`) and arm64 Release build
(`/tmp/sora-t13-release-build.log`). No release was published.


## T14 — Bash, SSH and explicit shell capabilities (2026-09-12)

Native testing first reproduced the hidden-input problem: semantic integration
could suppress the grid prompt even without an input mirror. The updated
Ghostty flag keeps Bash 3.2 and ordinary nested shells visible. The app's copyable
Bash setup activated command blocks; Unicode paste, block selection and scoped
search worked. The automation's Unicode typing omitted characters and its paste
acknowledgment timed out, so each paste was inspected before Return; the actual
pasted bytes, output and saved command were correct.

The native exporter produced a private source folder matching the pinned Ghostty
scripts, including their license notices. It was copied with SCP to a temporary
SSH server listening only on 127.0.0.1:18767, using disposable keys. No real host,
user SSH configuration or system Remote Login setting was changed. Plain SSH
showed a remote label and a visible prompt; Agent entry explained that it needs
a local tab. Disconnect restored the local folder and branch.

The exported Bash adapter displayed an explicit host and the remote folder
`remote dir-日本語;%25` without exposing local folder actions or a local branch.
Tab completed REMOTE_ONLY_COMPLETION.txt in that folder; its output was selectable
and searchable as a command block. A nested unintegrated zsh retained a normal
prompt. Sourcing the exported zsh adapter enabled its mirrored input, with Tab
still completing on the server. The remote shell used a UTF-8 locale at startup;
a C-locale Bash session escaped multibyte input, as recorded in the capability
matrix. Sora does not replace the host's locale.

Quit with an unsubmitted remote draft preserved both SSH_REMOTE_OUTPUT and
REMOTE_ZSH_MARKER with semantic boundaries. The archive and draft file confirmed
that the remote draft was not queued for local execution. Relaunch restored the
same tab/window UUIDs and local folder, with empty input; the restored remote
block remained searchable. Remote commands were absent from the local recall
index. Native Bash 5.2 also showed the correct red Exit 1 for `false` and then a
successful command; SQLite confirmed both statuses.

The command index and helper installer now isolate verification bundle IDs.
Before that change this fixture contributed six rows to the shared command
database; only those identified test rows and their matching transitions were
removed, with a private backup at /tmp/sora-t14-old-history-fixture-backup.json.
The production storage location remains unchanged. The owned Shell Fixture
window was closed, leaving the original two windows/four tabs and the exact
Beta draft. The loopback SSH server was stopped and its temporary keys removed.

Validation:

- Debug Sora build and all 358 tests: /tmp/sora-t14-final-check.log.
- Isolated native build: /tmp/sora-t14-final-native-build.log.
- arm64 Release build: /tmp/sora-t14-release-build.log.
- Focused Ghostty render-state test (`command block selection aligns`):
  /tmp/sora-t14-render-test.log, exit 0; GhosttyKit rebuilt successfully.
- `python3 Scripts/verify-shell-integration.py /bin/bash` and the same script
  against a temporary official GNU Bash 5.2 build: both pass setup/idempotency,
  Unicode, command identity, exit status, history exclusions and literal archive
  replay without evaluation. Logs: /tmp/sora-t14-bash32-final-verification.log
  and /tmp/sora-t14-bash52-final-verification.log.
- `git diff --check` passes. No release was published.

Remote command recall, Readline draft restoration, arbitrary multiplexer
integration, and automatic SSH reconnection are outside this implemented slice;
the [capability matrix](shell-integration.md) makes these limits explicit.

## 0.2.0 release package check

`MARKETING_VERSION=0.2.0 CURRENT_PROJECT_VERSION=19 Scripts/package-app.sh`
produced the Apple Silicon Release archive. Its embedded version/build and
required Ghostty, Sparkle, GPL and bash-preexec notices were checked; the app
passed `codesign --verify --deep --strict`. Packaging log:
`/tmp/sora-0.2.0-package-final.log`. The Bash 3.2 PTY verification also passed.

A separate copy of the packaged app was given the verification-only bundle ID
`dev.sora.release-verification` and re-signed locally, without modifying the
release archive. Native launch and `printf 'SORA_RELEASE_020_OK\n'` confirmed
command execution, semantic block rendering, a visible ready prompt, and the
Finished state in the Release configuration. Its owned tab was closed and the
QA app quit. The installed production app was left running and untouched.
