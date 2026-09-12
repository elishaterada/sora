# Agent harness verification

## H1 — 2026-09-12

- Sora Debug build succeeded; 278 tests passed (271 baseline plus seven goal tests).
- Command: `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO build test`.
- Scripted-provider checks cover premature advice, bounded corrections, absent
  evidence, a necessary question, completion audit returning to an action, Stop,
  prior-task evidence rejection, and strict decision parsing. Existing approval,
  cancellation, provider, terminal, and restoration tests still pass.
- Manually used the development build with the configured OpenAI provider to
  print `SORA_H1_CHECK`, capture output, and verify it without reading/writing files.
  The first run exposed overly vague completion-format feedback. After improving
  it, a fresh run captured exit-zero output, audited the evidence, and displayed
  **Goal completed** without a follow-up from the user. Inspected the status strip,
  command card, output disclosure, and completed state in the native window.
- This is a small live smoke check, not a completion-rate benchmark. The model
  can still make semantic verification mistakes; H8 tracks independent task
  assertions and controlled comparisons. Ordinary long-task, tab-switch, and
  restoration limits remain until the corresponding slices ship.

## H2 — 2026-09-12

- Debug build and all 284 tests passed. Used the same build/test command as H1.
- Regression coverage includes equivalent command fingerprints, unchanged cycles,
  failed launches fed back with concrete errors, timeout recovery, and refusing
  an interrupted write even after an intervening inspection. Stop still ends work.
- Live provider check executed exit 7, continued automatically, and caught a blank
  result from the next command instead of accepting exit zero. That run paused
  unverified after the model repeatedly misunderstood a literal as a variable.
  This exposed a model/protocol limitation, not successful goal completion.
  Corrective feedback now includes the exact envelope shape, and a conflicting
  older instruction to finish with prose was removed.
- Repeat protection is based on normalized action identity and observations;
  it cannot prove that differently spelled shell commands have identical effects.

## H3 — 2026-09-12

- Debug build and all 287 tests passed with the command above.
- Budgets belong to the task: 24 actions, 80 model requests (including action-format
  repairs), and 15 minutes of active work. Requests used to verify the last allowed
  action remain possible within the request/time limits. Waiting for a person is
  excluded. Estimated text tokens are labeled; provider billing usage is unavailable.
- Tests exercise a stalled stream reaching its deadline, late events after pause,
  preserved usage on follow-up, explicit extension, and checkpoint serialization.
- Inspected the native budget row in a live task. Durable loading of these saved
  checkpoints remains H5; no restart replay is authorized by H3.

## H4 — 2026-09-12

- Debug build and all 292 tests passed with the command above.
- Native readFile, listDirectory, literal searchFiles, gitStatus and gitDiff use
  internal typed calls/results. File reads reject devices/pipes and final symlink
  races; enumeration/output limits are explicit. Git inspection disables external
  diff, text conversion and filesystem-monitor helpers.
- Tests cover strict schemas, path/grant scope, symlink escape, bounded reads,
  search exclusions, external-diff suppression, approval, evidence and continuation.
- Live native read of the disposable `/private/tmp/sora-harness-smoke/note.txt`
  fixture captured `SORA_NATIVE_READ_VERIFIED` plus newline, audited the result,
  and displayed **Goal completed** without another prompt. No other files were
  requested or changed by that task.
- The earlier completion-format failure was corrected: supplemental findings are
  allowed when every criterion is covered; the separate evidence audit still runs.
  Regression coverage requires that audit before completion.
- Exact-read grants are an explicit separate user choice and can be revoked.
  This is not an OS sandbox: broad shell authority remains controlled by the
  existing command permission mode. General shell writes still require their
  own applicable approval; a native-read grant cannot authorize a write.

## H5 / T05 — 2026-09-12

- Debug build and all 297 tests passed with the command above.
- A window owns a separate AskSession for each tab; tab selection is presentation
  only. Closing a tab/window still warns for active agent work and cancels its
  own runtime. Provider/model preference changes do not cancel busy sibling tasks.
- Versioned checkpoints live under AgentWindows/window/Tasks/tab, separated by
  provider. Writes create private files before storing content and replace them
  atomically. Legacy conversation arrays remain readable; older shared files are
  preserved rather than guessed into a tab without identity.
- Tests cover tab independence, stable isolated paths, checkpoint restoration,
  unknown writes, stopped-task preservation, corrupt-file preservation and bounded
  recent context with original constraints retained. Omitted results are not made
  available as completion evidence in the current model context.
- Live check: submitted `sleep 8; printf SORA_TAB_SURVIVED`, immediately opened
  another tab, and returned to find the command complete and verification running.
  It reached **Goal completed**. Quit/relaunched the development app and reopened
  that task: transcript, captured result, completed state and exact budget counts
  were restored, with no new request or command.

## H6 — 2026-09-12

- Debug build and all 299 tests passed with the command above.
- Task-owned command runners expose stable process handles, bounded live output,
  bytes received, elapsed time and running status. Polling backs off from 250 ms
  to 4 seconds and uses no model requests. Quiet processes are shown as waiting
  for output, not misclassified as failures. Agent commands use a five-minute
  deadline capped by remaining task time; no-AI Programs retain 60 seconds.
- Tests inspect live output before exit, quiet work, handle identity, process-group
  cancellation, captured results and absence of an automatic continuation after Stop.
- Native live check completed a two-marker command with a 15-second wait and
  reached verified completion. In another run, expanded **Live output** while a
  30-second command was still running: saw `SORA_MONITOR`, elapsed time and bytes.
  Pressed Stop; the UI showed **Stopped**, exit 137, captured output and unchanged
  model-request count. The task did not resume itself.
- Interactive input remains unsupported by this noninteractive runner. Its
  capability description now says so explicitly; full REPL/TUI control remains
  outside this slice.

## H7 / U01 — 2026-09-12

- Debug build and all 302 tests passed with the command above.
- Users can send text steering while work runs. Updates are checkpointed, shown
  as queued, and applied before choosing another action. An action returned by a
  model that has not seen the update is retired; a running command retains its
  output and finishes unless the user presses Stop. Explicit user amendments
  take precedence over conflicting original wording without granting permissions.
- Tests cover steering during a model response, steering during a command,
  preserved evidence/budgets, no stale action execution, and follow/unread policy.
- Live steering check ran one delayed printf action, accepted an update requiring
  exact-marker verification and no further commands, and reached **Goal completed**
  with one action. The final answer included `SORA_STEER_CHECK`.
- The 302-message fixture emitted all 240 updates. Scroll-up held position and
  showed New response; clicking returned to the bottom. Output expansion and
  loading 40 earlier messages remained responsive, preserving request 131 in view.
  The fixture used no provider or transcript persistence. Previously documented
  AttributeGraph bulk-layout warnings remain; this verifies behavior, not a clean
  performance or warning-free claim. Returned to normal launch mode afterward.

## H8 — 2026-09-12

- Debug build and 304 tests passed; Apple Silicon Release build also passed with
  `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Release -destination 'platform=macOS,arch=arm64' ARCHS=arm64 build`.
  A generic universal Release attempt cannot link x86_64 against the repository's
  existing arm64 Ghostty binary; the supported Apple Silicon build is unchanged.
- Added a Debug-only paired fixture runner against the actual provider/runtime,
  independent visible-answer/result assertions, bounded per-case budgets and
  metrics. Release builds always keep the completion gate enabled.
- Final paired pilot: 3/3 verified with the gate, 1/3 without; 15 versus 8 model
  requests, zero human interventions and zero permission violations. Method,
  limitations, all development reports and final results are in [evaluation](agent-evaluation.md).
- Trial failures led to concrete fixes: canonical relative search paths, visible
  completion findings, preference for relative native paths, and evidence checks
  for explicitly named native inspections. These checks do not prove arbitrary
  semantic goals; later fixture expansion remains normal ongoing test work.

## 0.2.0 release review — interrupted native reads

The pre-release Spec review found that an interrupted native inspection's JSON
identity was treated as an uncertain write, permanently preventing the same read
within its goal. A regression test reproduced this through a saved running task,
relaunch, explicit Resume and fresh approval: no result appeared and the action
budget stayed at zero. The test failed before the fix
(`/tmp/sora-0.2.0-read-recovery-before.log`).

Native tool kinds and webpage fetches now supply runtime-owned replay safety.
Attempts persist that optional classification; older checkpoints remain readable.
An interrupted read can retry through the existing permission and budget gates.
Completed-action repetition, unchanged cycles and uncertain-write rejection remain
in effect. Shell text cannot impersonate a safe fetch through a `Fetch ` prefix.
All five native tool kinds, checkpoint round trips, completed-repeat rejection,
uncertain shell replay, and relaunch-to-approved-read execution are covered.

The focused follow-up review found the issue resolved. The complete Debug suite
passed all 361 tests with `xcodebuild -project Sora.xcodeproj -scheme Sora
-configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO
build test` (`/tmp/sora-0.2.0-final-check.log`).
