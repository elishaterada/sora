# Interactive agent commands

Updated September 23, 2026.

Approved commands have a live libghostty terminal in their command card. When a
command asks for input, Sora shows **Your turn** and focuses that terminal. There
is no Interact button, response field, Send button, or blanket password masking.
Type beside the prompt, use editing keys, and press Enter as in a normal terminal.
Programs control echo themselves: ordinary input is visible, while password
readers that disable terminal echo keep it hidden.

Prompt detection strips terminal formatting before recognizing confirmations,
passwords, press-enter prompts, questions and choose/select/enter instructions.
Unrecognized unfinished lines ending in `:`, `?` or `>` receive a 1.5-second quiet
period before handoff; completed log lines and ordinary percentage progress do
not. Entering the alternate screen hands control over immediately. These are
heuristics, not an operating-system guarantee that every blocked read can be
detected. The terminal remains visible and can be focused directly for an
unusual or silent prompt. No separate interaction mode button is required.

**Return control to agent** releases terminal focus and resumes the active timer.
The next model request still waits for actual command completion. Exiting the
command also returns control automatically. **Stop** kills the command tree and
does not resume the agent. Control-C goes to the program and suppresses automatic
agent continuation when the command finishes. Escape belongs to the program
while the command terminal is focused, including full-screen applications.

## Execution and ownership

`AgentCommandRunner` launches Apple's `/usr/bin/script -q /dev/null`, which owns
an isolated controlling PTY, then a fresh `/bin/zsh -f -o pipefail`. This supports
both stdin and `/dev/tty` readers without borrowing the user's normal shell.
The PTY starts with normal echo/newline handling and `TERM=xterm-256color`.
Native Git inspection tools explicitly disable color to keep their structured
results plain. The runner records the slave terminal path in a private temporary
directory so window-size changes can reach the real process through TIOCSWINSZ.

`AgentTerminalRelay` connects that already-running process to a hosted
`GhosttySurfaceView` using a local Unix socket in a mode-0700 directory. The
viewer runs the macOS `/usr/bin/nc -U` utility in a raw PTY to transport bytes.
Ghostty handles VT parsing, Metal rendering, keyboard encoding, mouse reporting,
selection, paste and terminal state. Sora does not implement another terminal
emulator or introduce a package dependency or application-owned FFI layer.
Opening or closing the viewer never reruns the approved command.

The relay uses nonblocking I/O, 64 KiB of queued input, 256 KiB of replay history,
and at most 512 KiB of queued display output. A slow viewer is resynchronized
with a visible omission notice. The runner retains the first 32 KiB for its
result and the most recent 32 KiB for detection/progress. Saved plain-text
excerpts remove color controls, normalize newlines and remove erased typing;
Ghostty receives the original bytes. These excerpts are logs, not exact snapshots
of a full-screen application's final grid.

Stop traverses the helper's descendants and process group because the helper
creates a separate session. Deliberately detached background services are not
a durable job-management feature. Closing the command cleans up the relay and
its private temporary files. Restarted apps do not reconnect to old processes.

The command's active deadline and the task's active budget pause during human
control. Each handoff has a ten-minute wall-clock limit. Returning control resumes
the remaining deadline rather than resetting it. A timeout never implies that a
write had no side effects.

Only the native terminal can submit raw user input; the model has no terminal
input-writing tool. Keystrokes are not independently saved or sent to providers.
Program output, including normal echoed input, is still captured as task evidence.
A program that prints secrets or fails to disable echo can expose them through
that output. Agent-terminal OSC 52 clipboard access is disabled; explicit native
Copy and Paste remain available.

## Warp reference

Studied the behavior and architecture of Warp's
[shell command executor](https://github.com/warpdotdev/warp/blob/master/app/src/ai/blocklist/action_model/execute/shell_command.rs),
particularly the transfer that waits for either user handback or command
completion. Warp's application code is AGPL v3 according to its
[licensing section](https://github.com/warpdotdev/warp#licensing). No Warp source
was copied or adapted. Sora uses its own Swift command/session structures and
its existing libghostty integration.

## Verification

The colored-choice regression failed before the fix: the prompt did not trigger
handoff. Tests now cover that case, quiet-period fallback, progress negatives,
raw terminal transport, Backspace/Enter, terminal resize, cleanup, password echo,
plain-text transcript formatting, deadline restoration, automatic continuation
exactly once, and stopping without continuation (including Control-C).

Commands used:

```sh
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO test
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug \
  -destination 'platform=macOS' build
git diff --check
```

The final suite ran 399 tests: all functional checks passed, including the new
Control-C case. One existing two-second history-sanitization timing check took
2.31 seconds during a busy run and passed on its isolated retry; its threshold
and implementation were not changed. The final Debug build and diff check passed.

The Debug-only `--sora-command-input-test` fixture now presents a colored
`Choose a number [1-3]:` prompt followed by a password prompt. In the native UI,
the first prompt automatically received focus; typing `x`, Backspace and `2`
showed only `2` beside it. Enter advanced to the password prompt; a dummy response
was not echoed or included in the final result. The command finished with exit 0
and confirmed choice 2. A final keyboard check verified that Escape stayed in
the terminal and Control-C produced Command stopped. This fixture performs no
provider requests or transcript
writes. Existing SwiftUI AttributeGraph diagnostics still appeared; interaction
and completion remained responsive.

## Remaining limits and next issue

Prompt detection is heuristic. Reattaching the viewer replays bounded recent
bytes, so a long-running full-screen program may need to redraw if its initial
screen setup has left the replay buffer. Task logs remain bounded text excerpts.

Next issue: preserve the rendered command-terminal state across panel reopenings
so long-running full-screen programs never depend on bounded byte replay.

## Release verification — 0.6.0

The release was prepared in an isolated checkout of 0.5.0, excluding unrelated
local work. All 393 tests passed with `xcodebuild -project Sora.xcodeproj -scheme
Sora -configuration Debug -destination 'platform=macOS'
-parallel-testing-enabled NO test`. `Scripts/package-app.sh` built the Apple
Silicon Release package with version 0.6.0 and build 26; `codesign --verify
--deep --strict` passed. The prompt, editing, password echo, Escape, and Control-C
manual checks described above exercised the same interaction implementation.
