# Agent completion evaluation

The suite tests Sora's actual AskSession and native tools against disposable local
fixtures. Normal app launches never run it. Debug launch only:

```sh
/path/to/Debug/Sora.app/Contents/MacOS/Sora --sora-agent-evaluation /tmp/sora-agent-evaluation.json
```

It uses the configured provider/model and Keychain credential, so it makes billable
provider requests. It uses isolated preferences, Programs, conversation files and
fixture directories; it does not change the user's permission settings or inspect
user project files. Native inspections inside the fixture run under Approve for me.
Actions requiring approval end that case rather than being granted automatically.
Fixture folders are removed afterward; the JSON report retains action traces.

## Conditions and assertions

Three fixtures cover a direct read, search followed by an explicitly requested
readFile inspection, and recovery when a named report is in a subfolder. Each case
runs with the same model, prompts, tools, permissions and budgets, with the completion
gate toggled on/off. Order alternates by case. The off condition ends on ordinary
prose and accepts a completion decision without a second audit. It is not a complete
recreation of an older Sora version and is not Warp.

The external fixture oracle requires the expected marker in the displayed final
answer and an actual successful, untruncated native file read. Unsupported claims,
a matching search alone when readFile was requested, and reads outside the fixture
cannot pass. This narrowly verifies these tasks; it is not a semantic oracle for
arbitrary programming, security, or product-design work.

Reports include verified completion, premature endings, required human intervention,
permission violations, recovered failures, actions, requests, estimated text tokens,
elapsed time and terminal state. Token counts are estimates, not billing usage.
Request/action/deadline caps bound every run. Unit tests separately exercise approval,
Stop, stalled loops, timeouts, corrupt checkpoints, steering and the fixture oracle.

## Recorded pilot — 2026-09-12

OpenAI API, `gpt-5.4-mini`, one paired run per fixture with the final implementation:

| Metric | Gate off | Gate on |
| --- | ---: | ---: |
| Verified tasks | 1/3 | 3/3 |
| Model requests | 8 | 15 |
| Estimated text tokens | 25,770 | 55,344 |
| Total elapsed seconds | 16.9 | 19.0 |
| Human interventions | 0 | 0 |
| Permission violations | 0 | 0 |

[Final recorded results](evaluations/2026-09-12-verified.json). Temporary directory
prefixes are replaced with `<fixture>` in checked-in reports.

This small pilot is encouraging but does not establish a reliable completion rate,
a latency improvement, or superiority to Warp. Model variance was visible across
runs. Keep the extra request/token cost visible and broaden the fixtures before
making general performance claims.

Earlier development trials are retained for transparency:
[initial](evaluations/2026-09-12-initial.json),
[tool guidance](evaluations/2026-09-12-tool-guidance.json), and
[visible-answer oracle](evaluations/2026-09-12-visible-answer.json).
They used evolving guidance/oracles and must not be pooled into a single controlled
result. They exposed tool-routing failures, malformed relative paths under macOS
aliases, hidden completion findings and skipped explicit readFile requirements.
The runtime now checks explicitly named native inspections against actual results;
user amendments can withdraw a requirement. This does not make general model review
infallible or widen tool authority.
