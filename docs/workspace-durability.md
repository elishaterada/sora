# Workspace durability investigation — 2026-09-12

The reported sequence was update notification → Install → quit → reopen, followed
by missing tabs. We reproduced a concrete data-loss path in the old window store:
two instances loaded the same preferences catalog, the first added tabs, and the
second saved its older cached catalog. The newer tabs disappeared. The regression
test failed before the fix. This demonstrates a loss mechanism; it does not prove
that concurrent copies caused the reporter's particular incident.

The installer and shell bootstrap do not clear history. Production Debug and
Release configurations use `dev.sora.app`. Command history is committed to
`~/Library/Application Support/Sora/history.sqlite`; output and drafts live under
`Sora/TerminalHistory/<tab UUID>.txt` and `.txt.draft`. Replacing the app bundle
leaves these files intact. Losing the tab catalog also loses the references to
those archives, which can look like history deletion.

## Storage and lifecycle changes

- The authoritative workspace catalog is now
  `~/Library/Application Support/Sora/Workspace/windows.json`, with a versioned
  envelope, stable window/tab UUIDs, and per-window revisions. It is independent
  of install path, app version, and macOS preferences restoration.
- Existing window preferences migrate once, falling back to the older
  single-window snapshot only when no window catalog exists. Both original
  preference records remain untouched. An intentionally empty catalog stays
  empty instead of resurrecting older tabs. Nonproduction bundle identifiers use
  `Sora/Development/<bundle ID>/Workspace` to isolate verification workspaces.
- Each change locks, reads, and updates the current file. Changes to independent
  windows merge. A stale revision cannot overwrite newer tabs or resurrect a
  closed window. The rejected copy displays a persistence error and must be
  reopened before it can edit that window's saved state.
- Checkpoints use atomic replacement, file and directory synchronization,
  private directories (0700), and private files (0600). A previous valid catalog
  is retained in `windows.json.backup`. A damaged primary recovers from that
  backup while preserving the original bytes in a separate unreadable file.
  Unknown versions and unrecoverable data are kept intact; a blank launch cannot
  overwrite them. Errors remain visible with a Show Saved Data action.
- Tab selection now saves immediately, alongside add/rename/reorder/close and
  directory changes. Quit approval and AppKit termination both checkpoint and
  flush output. Sparkle's `willInstallUpdate` and relaunch callbacks also flush
  before installation proceeds. An update checkpoint does not mark termination
  approved, so cancelling a later quit leaves ordinary window closing intact.
- Window teardown deletes a record only after an explicit, approved window-close
  request. Teardown during relaunch or quitting preserves open windows. Closing
  a window flushes its history writer before the controller can be destroyed.
- Shell startup cannot replace existing archives or drafts before initialization
  finishes. When the shell is waiting for input, the synthetic final marker added
  by the native exporter is separated from real output before trimming trailing
  unsubmitted prompts. The literal draft stays in its own file. Running commands
  and ambiguous older blocks remain intact; they are not guessed to be drafts.

The store is local persistence, not cross-process collaborative editing. A stale
app copy is prevented from saving a changed workspace; use one installed copy for
normal work. Old releases that only understand preferences cannot read newer
file checkpoints. Downgrading therefore shows the retained pre-migration state.

## Verification

`WorkspaceRestoreTests.testStaleProcessCannotDiscardAnotherProcessesNewTabs`
failed against the old implementation and passes with this change. Coverage also
includes migration, preference reset, repeated relaunch, multiple windows,
explicit versus incidental teardown, stale close resurrection, unreadable data,
future formats, backup recovery, file permissions, decoded empty snapshots,
history writer flushing, per-tab SQLite reopen/migration, and unfinished drafts.

Commands used:

```sh
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO build test
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Release \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 build
```

The final Debug build and all 321 tests passed. Apple Silicon Release was built
as well. Test output includes existing sandbox-extension warnings from temporary
file pasteboard fixtures; there were no failing assertions.

Native verification used the separate `dev.sora.verification` app, with Alpha
and Beta tabs, another window with a split pair, a recognizable printed result,
and the unsubmitted `echo durable-draft` buffer. Migration, ordinary restart,
and forced termination retained the window/tab identities, names, selection,
split layout, output, and draft. SQLite retained exactly one matching executed
command and zero executions of the draft.

A disposable installation under `/tmp/sora-update-verification` then received a
real Sparkle update from a loopback HTTP server. The feed and archive were signed
with a newly generated temporary Ed25519 key; the production update feed and keys
were not used. The native review window displayed the test release notes. Install
Update → Install and Relaunch changed build 1001 to 1002. After quitting and
reopening the updated app, both windows, all four tab IDs, names, selection, split
pair, printed output, and literal draft still matched the pre-update state.
The installed user app was left running throughout.

The same signed update sequence continued through builds 1003 and 1004 to verify
final export handling. A fresh printed result and draft then survived quit and
reopen with zero draft copies in the archive and zero draft executions in SQLite.
Explicitly closing that additional test window removed only its catalog record;
a final quit preserved the original two windows and four tabs. The local server
was stopped and its temporary signing key removed afterward.

## Limits and recovery

The specific reporter's machine/version sequence has not been reproduced. The
fix addresses demonstrated stale-write loss and hardens update/quit handling.
A real release still follows `releasing.md`; no release or tag was published.

Output is intentionally capped at 2 MB per tab, drafts at 100 KB. Abrupt process
or machine failure can lose output since the ten-second checkpoint; running
processes are recreated as new shells. Completed command history is stored
independently in SQLite. This change cannot reconstruct files already deleted
by an older version or an external cleanup tool.

When investigating a user's missing workspace, preserve the preferences plist,
`Workspace` directory, `TerminalHistory`, and `history.sqlite` before recovery.
Match archive UUIDs to available catalog backups. Do not automatically import an
older nonempty catalog over an intentionally closed workspace. If both file
catalogs are unreadable, keep them and recover deliberately from a known valid
snapshot; the app will show the save error instead of replacing them.
