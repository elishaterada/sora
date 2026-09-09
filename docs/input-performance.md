# Typing performance investigation — September 8, 2026

## Scope and environment

Investigated sluggish typing reported on Sora 0.1.9 (10), macOS Tahoe 26.6.2,
M5 MacBook Pro, 48 GB RAM. Local measurements used an M4 Pro MacBook Pro on
macOS 26.6.2 (25G83), with optimized arm64 Swift code and a Release app.
The baseline is commit `f4d80c9`, before the performance changes.

These measurements cover Sora's input handler, prompt wrapping, filesystem
completion, a large history database, and the bundled zsh hooks. They are not
input-to-photon measurements and do not establish display latency on the M5.
Different shell plugins, network directories, thermal state, external displays,
and GPU load can change perceived latency.

## Findings and changes

- Completion enumerated directories and queried SQLite synchronously on the main
  thread, sometimes repeatedly for a key and its PTY echo. In a 10,000-file
  directory, one scan took approximately 18–65 ms. Completion now uses a serial
  worker, with one lookup in flight and only the newest pending request retained.
  Identical completed requests are not repeated on PTY wakeups. Results are
  applied on the main thread only if their input and directory still match.
  Edits immediately invalidate old suggestions, so Tab cannot accept stale text.
- Fullscreen program input previously went through shell completion. A final ZLE
  redraw can arrive after Return and incorrectly mark the shell prompt ready.
  The bundled shell now emits an explicit command-start marker after that redraw.
  Sora clears prompt state and sends fullscreen keys directly to libghostty.
- Prompt wrapping shaped every growing character prefix on every layout. It now
  finds fitting runs with exponential/binary search, and caches unchanged layouts.
  Repeated chip titles, caret state, readiness, selection clearing, and hint text
  avoid some unnecessary UI work.
- The zsh highlighter created a subshell to check each command on every redraw.
  It now uses the builtin directly. Optional coloring skips buffers longer than
  1,024 characters; editing, execution, and prompt mirroring still work.
- Input still flushes libghostty actions. Those flushes no longer depend on
  completion refresh, and the redundant refresh-time ticks were removed.
- `Terminal keyDown` Points of Interest signposts allow future Instruments
  measurements without logging typed text.

No Ghostty code was copied or changed, and no dependencies were added.

## Results

Warm text shaping; wall-clock milliseconds. Component benchmarks use 30 wrap
samples and 10–30 directory samples. Shell PTY tests use 591 individual keys
through an isolated zsh editor, including its complete redraw hook.

| Measurement | Before | After |
| --- | ---: | ---: |
| 40-character wrapping, median | 0.265 ms | 0.066 ms |
| 200-character wrapping, median | 0.955 ms | 0.277 ms |
| 2,000-character wrapping, median | 8.048 ms | 2.614 ms |
| 10,000-character wrapping, median | 40.413 ms | 13.624 ms |
| Shell PTY key/redraw, median | 1.556 ms | 0.980 ms |
| Shell PTY key/redraw, p95 | 2.429 ms | 1.918 ms |
| Matching directory scan, 10,000 files | ~61 ms on main thread | ~63 ms on worker |

An Instruments Time Profiler trace of the optimized native app captured 206
`Terminal keyDown` intervals: median **0.038 ms**, p95 **0.068 ms**, maximum
**0.188 ms**. This measures the handler through terminal dispatch, not the time
until the glyph is displayed. The trace predates the final command-start marker
fix; that fix changes shell mode transitions rather than the timed handler.

A blocked-worker stress test enqueued 1,000 successive edits in approximately
**0.5–0.7 ms total**, retaining only the newest pending result. A 100,000-row
history lookup took roughly **448–465 ms** wall time while running asynchronously.
The lookup itself still has room for optimization; typing does not await it.

## Reproduction

```sh
python3 Scripts/benchmark-input.py --ref f4d80c9
python3 Scripts/benchmark-input.py

xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Release \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -parallel-testing-enabled NO test

xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

The benchmark creates only temporary files and an isolated `zsh -dfi`; it never
submits the generated typing sample as a shell command. Release architecture is
explicit because the bundled GhosttyKit supports arm64; an unrestricted Release
build also attempts unsupported x86_64 linking.

In Instruments, attach Time Profiler to a Release Sora process, type at a shell
prompt and inside a fullscreen CLI, and inspect `Terminal keyDown` in Points of
Interest. Include a long command, backspace, cursor movement, completion, tabs,
and sustained output. Keep trace files local: Instruments may capture process
environment and other private metadata even though Sora's signposts contain no
input text.

## Verification and limits

The final Release test suite passed **225 tests**, and the Debug build passed.

Regression coverage includes stale asynchronous results, editing before Tab,
a blocked completion worker, burst coalescing, a 100,000-row database, Unicode
and multiline wrapping, bounded shaping work, long-buffer highlighting, and the
shell's command-start transport. Existing terminal, completion, shell, Agent,
workspace, and notification tests also run.

Manual checks used an isolated Release bundle to preserve existing user sessions:
individual typing, a 200-key burst with wrapping, multiline editing, and Vim
input with Tab/Right Arrow. The final build also correctly switches its footer
from Ready to Running when Vim starts and back to Ready when it exits. Clipboard-based automation timed out, so native
large-paste verification is not claimed; component tests cover long buffers.
The user's exact M5 setup and Codex CLI session still require a local check with
the updated build. No release has been published by this task.
