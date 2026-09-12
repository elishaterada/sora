# Goal-oriented Agent harness

Design direction recorded 2026-09-11. The user wants Sora to accomplish requested
work, try alternative approaches when necessary, and involve a human only when
that human can unblock progress. Implementation is tracked by H1–H8 in the
[roadmap](roadmap.md). H1–H8 are implemented in the working tree on 2026-09-12; see the
[verification record](verification-agent-harness.md). The sections below retain the original design rationale; current behavior and
limitations are recorded in the verification and evaluation documents.

## Product outcome

An execution request creates a task with an outcome that survives individual
model responses. The Agent gathers context, takes an authorized action, inspects
the result, and continues until the outcome is verified or a specific condition
requires pausing. A request for an explanation remains an explanation; describing
how to do something must not trigger unintended changes.

For example, “Fix the failing test” should lead to reproducing the failure,
examining the relevant code, proposing an authorized fix, applying it, and running
the relevant checks. An unsuccessful fix should lead to another diagnosis and
approach. “Here are commands you could try” is an intermediate suggestion, not
completion of that execution task. “Explain this test failure” can legitimately
finish with a supported explanation.

Goal persistence and action authority are separate. The existing permission mode
continues to apply. Under Ask for approval, actions still require approval;
Approve for me only auto-runs its validated read-only grammar. Existing Full
access is an explicit user choice, not a prerequisite for using goals. No goal,
retry, summary, or model-generated plan can grant itself additional authority.

## Baseline findings before H1–H4

The pre-H1 source already asked the model to keep working. The gap is also in
the surrounding runtime and tools:

| Current behavior | Practical consequence |
| --- | --- |
| `AIRequest.instructions` encourages concrete actions, but `AskSession.finish` accepts a normal prose reply as a completed response without checking the task outcome. | The model can give advice or premature conclusions and end the execution loop. |
| The shell continuation requests findings and a useful next step; the webpage continuation more explicitly asks for goal completion. | Different tools give different signals about whether the model should continue. |
| `commandCount` caps a turn at six actions and resets on a new user send. | The user must nudge longer tasks; there is no durable task budget. |
| A 60-second command timeout asks for a follow-up; command-launch errors surface without a recovery continuation. | Ordinary operational problems can become unnecessary human handoffs. |
| Repairs address malformed action envelopes, with no general attempt ledger or completion verifier. | Protocol recovery does not ensure task recovery or prevent repeated ineffective strategies. |
| Each command uses a fresh noninteractive `zsh -f`; stdin is closed and shell state does not persist. | Stateful and interactive workflows cannot be handled as though they were a normal terminal session. |
| `bindTab` stops active work; per-window snapshots are not a durable task browser. | Navigating tabs or restarting interrupts continuity. |
| Context is reconstructed from complete message pairs and rejected above a byte cap. | A long task has no compact, authoritative record of goals, evidence, and remaining work. |
| Instructions describe automatic actions without reflecting the selected permission mode exactly. | The model may assume an action can happen without the user decision the runtime actually requires. |

Source anchors: [AI request instructions](../Sora/Agent/AIProvider.swift),
[session loop](../Sora/Agent/AskSession.swift),
[command execution and permission policy](../Sora/Agent/AgentCommandRunner.swift),
and [conversation storage](../Sora/Storage/AIConversationStore.swift).

These are plausible contributors to the user's observed difference from Warp.
We have not established a controlled same-model performance comparison. Model
quality, available tools, and task mix also affect completion.

## H1: the first vertical slice

Add a small provider-neutral goal/decision model and a completion gate around the
existing action loop. Keep the current tools, six-action ceiling, 60-second
deadline, and permissions for this slice. Do not introduce a new agent SDK or
rebuild the terminal.

An execution task records the original request, working directory, constraints,
and concise success criteria. Straightforward tasks can infer criteria and start;
do not require a plan-approval ceremony. Missing information that changes the
target, authority, or irreversibility requires a focused question. User steering
updates the task explicitly; the model cannot quietly narrow the goal to make
completion easier.

Normalize each model response into an internal decision: propose an action,
request a necessary user decision, or propose completion with evidence. Plain
prose on an active execution task goes through this gate rather than silently
ending it. Invalid or advisory-only decisions get bounded corrective feedback.
Explanation-only turns bypass execution-specific evidence requirements.

Evidence references must identify actual recorded tool results or user-supplied
facts relevant to the criteria. Exit code zero alone is insufficient: creating a
file successfully does not prove it contains the requested result. Use cheap
deterministic checks where possible and a bounded model review for semantic
requirements. A second model review is fallible, not proof; unsupported outcomes
stay unverified. Claim only what the available evidence establishes.

H1 stops at the existing action budget and after at most two consecutive
non-actionable decision corrections. Show an accurate pause reason and preserve
the task instead of calling it complete. Count corrective model calls separately
so they cannot loop invisibly. H2/H3 generalize this bounded behavior.

Minimum H1 scripted-provider scenarios:

- Execution request receives “you should run…”; Sora continues to a concrete
  proposal within the same goal instead of asking the user to repeat the request.
- Completion claims refer to absent results; the task stays unverified and seeks
  a relevant check, subject to the normal permission policy.
- A command exits successfully but its output fails a success criterion; work
  continues rather than equating process success with task success.
- Verified criteria lead to one completed outcome summary, with no extra action.
- An explanatory question returns an answer without executing commands.
- A required permission/missing input produces a specific waiting state.
- Stop during streaming, approval, or execution prevents queued continuation;
  existing cancellation and stale-event protections still hold.
- Budget exhaustion and repeated non-actionable responses pause visibly without
  false completion or silent budget reset.

## Runtime loop and state

Use a small Swift orchestration type outside SwiftUI. `AskSession` can remain the
presentation adapter while orchestration ownership moves out incrementally.
Provider adapters translate protocol details under `Providers/`; internal goal,
tool, result, permission, and decision types must not depend on their schemas.

The runtime repeatedly: assess remaining criteria → choose an action → check
authority → execute → record observation → verify or revise the approach.
Progress text is separate from the decision to finish. A completed provider
response is not a completed task.

| State | Meaning and exit condition |
| --- | --- |
| Working | Inspecting, acting, recovering, or verifying; continue within available authority and budget. |
| Waiting for approval | One concrete action needs permission; approval resumes only that applicable action/scope. |
| Waiting for input | A missing fact or decision prevents useful progress; ask what unlocks it. |
| Waiting for process/external result | A task-owned operation is still progressing; wait or poll with backoff and a deadline. |
| Paused | A budget, stalled strategy, unsupported capability, or recoverable infrastructure condition prevents continuation; retain a precise reason. |
| Stopped | The user canceled; never restart from a late event, tab switch, or timer. |
| Completed | Relevant evidence supports the requested success criteria. |
| Failed | An unrecoverable runtime/storage failure prevents safe continuation; preserve available diagnostics and avoid a success claim. |

State transitions and validation should be testable without SwiftUI or live API
calls. Avoid a large generic workflow framework; add ownership and states only
as each roadmap slice needs them.

## Recovery that makes progress

Record each attempt's action identity, target, relevant inputs, result, failure
category, and the observation that justifies the next approach. Distinguish
missing prerequisites, invalid arguments, permissions, unsupported interaction,
transient service errors, truncated output, and successful actions that did not
meet the goal.

Prefer the smallest useful alternative: inspect a missing tool's actual path,
read a relevant subsection instead of an oversized output, try another source
when a page is unhelpful, or change the hypothesis when a test still fails.
Do not treat cosmetic changes to the same failed command as a new strategy.
Transient retries may repeat an action only when it is safe to repeat and a
specific changed condition/backoff justifies it. Authentication failures and
exhausted credit require a relevant user action, not repeated spending attempts.

Timeouts and launch failures become observations. A timeout does not imply that
nothing changed: check the outcome before retrying a write. A user Stop is final
for that run and must never be mistaken for a timeout to recover automatically.
Unavailable tools/permissions are not obstacles to bypass; try an authorized
alternative or state exactly what capability is needed.

H2 detects repeated action/result patterns and unchanged criteria. After bounded
alternative attempts, pause with what was tried, what remains, and what new
information would justify continuing. Do not ask a meaningless question just
because the model ran out of ideas.

## Budgets, tools, and long-running work

H3 uses task-level limits for actions, elapsed active work, provider requests,
and tokens where usage is available. Treat monetary cost as an estimate only
when rates and usage are known; unknown cost is not zero. Soft checkpoints
summarize progress and continue within the hard limits. Hard limits pause and
offer an explicit extension; limits cannot be renewed by internal follow-ups.
Account for time spent waiting on a human separately from active execution.

H4 adds typed, bounded inspection tools so ordinary discovery does not require
fragile shell strings. Keep exact shell proposals available for broader work.
Classify authority from validated arguments, paths, side effects, and current
policy, not just a tool's name or a model's “read-only” claim. A scoped grant is
valid only while its action/resource scope and inputs remain applicable; edits,
revocation, and broader targets require reevaluation. Existing single-action
approval must never be silently promoted to a broad grant.

Generate capability/permission descriptions from runtime state. File contents,
webpages, command output, and attachments remain untrusted reference data and
cannot modify goals, grants, or budgets. Send only task-relevant context obtained
through the applicable permission flow. Keep credentials in Keychain and out of
task journals. Model/provider changes remain explicit user choices.

H6 introduces task-owned processes with handles, incremental output, status
checks, and cancellation of their own process groups. A foreground observation
timeout can yield to monitoring instead of killing a healthy long-running job,
but hard deadlines still apply. Do not inject commands into the user's occupied
PTY or kill unrelated processes. Interactive authentication and unsupported
prompts need a clear handoff until a dedicated interaction capability is shipped.

## Durable context and recovery

H5 stores a versioned local task record: stable task/tab/window/provider identity,
original goal and amendments, criteria, observations, attempt history, pending
decisions, valid grants, budgets, and transcript references. Write an action's
intent before dispatch and its result afterward. A crash between those writes
means outcome unknown; inspect the external state before considering replay.

Restore interrupted tasks as paused checkpoints. Do not replay commands or resume
spending automatically on relaunch. Switching tabs or dismissing the Agent view
only changes presentation. Closing a task/window and quitting retain their
explicit cancellation/close-warning behavior.

Keep a bounded working summary with stable references to original evidence.
Preserve goal constraints and permission boundaries outside lossy model summaries.
Failed attempts remain useful observations even when a partial assistant answer
cannot be treated as a completed answer. Compaction must not mark unverified
criteria complete, forget negative results, or turn a quoted instruction into
user authority. Save private files atomically and surface storage failures.

## Human interaction

The main view shows a short goal, current action, progress, and outcome state.
Details disclose tool output, changed files, verification evidence, and attempts
on demand. “Trying a different source because this page has no usable content”
explains meaningful progress; repeated “still working” messages do not.

Ask only when the answer changes the path forward: a required permission, a
missing target/credential, a consequential choice, or an extension of the agreed
limit. State the exact action or missing fact and why it matters. Do useful
independent work while an optional question is pending; silence never approves
dependent actions. Retain valid prior answers/approvals within their scope.

Support steering without losing the original task, explicit Stop and Resume,
and a concise completion message describing what changed and how it was checked.
Offer next steps only after completion or when a real blocker makes them
necessary; do not hand the remaining authorized work back as advice.

## Evaluation and rollout

Start H8's fixtures with H1 and extend them with each slice. Use temporary local
workspaces, scripted providers, and fake clocks/processes for deterministic
control-flow tests. Add end-to-end local tasks covering a failed test and repair,
a missing prerequisite, unhelpful webpage, truncated logs, command timeout,
multi-action workflow, required approval, Stop races, tab switching, restart,
and an uncertain write outcome. Test ordinary questions and impossible tasks too.

Run controlled baseline-versus-harness comparisons using the same provider/model,
task inputs, permissions, and budgets; repeat stochastic runs and retain traces.
Score outcomes with independent fixture assertions, not only the model's claim.
Measure verified task completion, false success, unnecessary human interventions,
repeated ineffective attempts, recovery success, latency, and provider usage.
Count necessary approvals separately from avoidable clarification.

Require all deterministic permission/cancellation/completion tests to pass and
zero permission bypasses or false successes in the mandatory fixtures. Define
the live task set and improvement threshold before the trial; publish observed
results rather than inventing a target success rate. Unit tests alone do not
establish improved real-world agent behavior.

## Decisions and limits

- Start with H1 around existing tools, followed by evidence-driven recovery.
  A stronger prompt supports the runtime contract but cannot enforce it alone.
- Preserve Apple-native UI, libghostty ownership, provider independence, and
  AI-disabled terminal behavior. No additional runtime dependency is proposed.
- Keep one agent per task initially. Multi-agent delegation, a new provider SDK
  harness, cloud execution, accounts, and sync are not needed for the first win.
- H3's exact default budgets and H4's additional grant scopes require product
  review with concrete UI and evaluation evidence before shipping. Current
  defaults remain unchanged until then; these do not block H1.
- Semantic verification is imperfect. Unsupported or unverifiable criteria must
  remain explicit limitations, not be silently converted into success.

## Behavioral references

Anthropic documents premature completion and lost context in long-running tasks,
and reports benefits from incremental work, progress artifacts, and end-to-end
verification. These support the direction, not a guarantee for Sora's task mix.
[Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).

Warp documents persistent plans and interaction with long-running terminal
applications. Those are capabilities beyond Sora's current one-shot command
runner and help explain why some tasks have fewer dead ends there.
[Warp Agents 3.0](https://www.warp.dev/blog/agents-3-full-terminal-use-plan-code-review-integration).

References reviewed 2026-09-11. Study behavior and architecture only; do not copy
AGPL Warp implementation code or add Warp as a runtime dependency.
