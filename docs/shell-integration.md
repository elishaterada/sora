# Shell and SSH integration

Open **Help → Shell Integration…** (also available in the command palette).
New local zsh tabs are configured automatically. Copy Bash Setup or zsh Setup
for a nested shell and review the command before running it. For SSH, export
scripts, copy the whole folder to your server, and source `sora.bash` or
`sora.zsh` there. The included README explains optional startup-file setup and
removal. The app does not edit SSH configuration or remote startup files.

## Capabilities

| Environment | Blocks, selection, output search/filter | Input and Tab completion | Context and Agent | Relaunch |
| --- | --- | --- | --- | --- |
| Local zsh with Sora integration | Yes | Native mirrored input; Sora completions with shell fallback | Local folder/branch and optional Agent | Same tabs, archived output and unsubmitted zsh draft |
| Local Bash 3.2 / 5.2 with adapter | Yes | Visible Readline prompt; Bash owns completion | Local folder/branch; explicit Agent entry | Same tabs; saved output replays when the adapter is sourced in startup; no Readline draft restoration |
| SSH zsh with exported adapter | Yes | Mirrored input; remote zsh completes | Host and remote folder, display-only; Agent unavailable in this tab | Saved output in a fresh local shell; no automatic login or remote-draft replay |
| SSH Bash 3.2 / 5.2 with exported adapter | Yes | Visible Readline prompt; remote Bash completes | Host and remote folder, display-only; Agent unavailable in this tab | Saved output in a fresh local shell; no automatic login or remote-draft replay |
| SSH without adapter, unsupported shells or intercepted metadata | Ordinary terminal and whole-output search remain available; block features require semantic markers | Terminal grid and foreground program own input | A detected SSH/mosh/telnet client shows remote context without local folder actions | Saved tab identities and output; rich replay depends on shell setup |

These are supported, verified slices, not a claim of parity across every shell,
server or multiplexer. Bash 3.2 and 5.2 were exercised on macOS; the exported
scripts require Bash/zsh and the normal tools their bundled Ghostty integration
uses. Remote Unicode input requires a UTF-8 locale at shell startup. When the
server lacks `xterm-ghostty` terminfo, `TERM=xterm-256color ssh your-host` is a
clean fallback. The SSH fixture used this fallback.

## Context boundaries

The shell sends bounded, encoded metadata with shell, host, locality and path.
An SSH/mosh/telnet foreground process overrides any local claim. Remote reports
are tied to the local foreground process identity; after disconnect, a different
local shell does not inherit the remote report. A remote path is never made into
a local file URL. Folder actions, local Git lookup, Sora filesystem suggestions,
local command recall/insertion and Agent entry are disabled in remote tabs.
Local image drops explain that the file must first be transferred to the host.

Remote output remains searchable in the tab's saved terminal archive and can be
bookmarked as a read-only copy. Remote commands are not inserted into the local
command-recall database. New tabs/splits inherit the last local folder, not a
remote path. Local and remote shell capabilities are separate: a mirrored remote
zsh line enables its native display while completion and execution stay remote.

Ghostty's semantic block styling no longer implies that input must be hidden.
A per-surface flag hides the grid's editable line only after Sora receives an
authoritative mirror. Entering a command clears the flag; ordinary Bash and
unintegrated nested shells keep their visible input and cursor. The terminal
still owns rendering, PTY state, selection and output matching.

## Bash compatibility

Sora's adapter sources the bundled unmodified Ghostty integration. It uses its
existing hook arrays on Bash 3.2 and PS0/PROMPT_COMMAND on modern Bash, preserving
user hook entries. The pinned modern Ghostty prompt wrapper loses the prior exit
status through a local declaration. Sora calls the same prompt hook with the
captured command status restored; the bundled source is unchanged.

Command titles use ASCII percent transport, preserving UTF-8 and literal percent
sequences across bounded chunks. The adapter compares history entries before
capturing a command; HISTCONTROL/HISTIGNORE or disabled history cannot make the
previous command appear to have run again. It avoids replacing user DEBUG traps
or Readline keybindings. Source the adapter after theme/startup configuration.

The export includes complete third-party source and license notices; see
[licensing](licensing.md). There is no remote Sora process, account or service.
The standalone verification script uses Python's standard library to exercise a
disposable shell PTY; Python is not an application dependency.
