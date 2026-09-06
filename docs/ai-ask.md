# Native Ask: optional AI providers

Authorized on 2026-09-04 by the user's requests to implement AI with OpenAI API,
Codex, Anthropic API, Vercel AI Gateway, and Grok (xAI). This supersedes the earlier no-AI
scope restriction for this slice. On 2026-09-05 the user authorized persistent
agent mode, bounded command execution, and automatic troubleshooting. Accounts,
sync, and a hosted backend remain deferred.

## User flow

At a ready shell prompt, type a clear conversational request such as
`Help me find the largest files`. Sora labels the line **↵ agent** while
typing. Press Return to cancel it as shell input and continue into Agent in the
same terminal tab. Agent opens as a translucent overlay on the live grid (the
Metal surface stays visible underneath). **ESC for terminal** dismisses the
overlay without stopping a running answer. A reserved 36pt resume slot above
the sticky prompt shows the agent title when you return; click it or press
**⌘Y** to reopen. Context chips are clickable: working directory and git
branch in the chrome/sticky bar open Reveal/Copy actions; agent replies link
filesystem paths (click to Reveal in Finder); the Ask status model label opens
Setup; proposed commands expose Copy. Each new terminal→agent handoff starts a
fresh conversation for that tab; other tabs keep their own threads. Press
**Cmd+Return** to force a detected sentence to run in the shell. The canceled
request may remain visible
in terminal scrollback, but it is never submitted as a command. No separate Ask
window is created.

Routing is local and recovery-oriented. Conversational prefixes (`help me`,
`how many`, …), `/agent ` (prefix stripped), and any line whose primary command
is not a zsh builtin and not found on the login-shell PATH go to the agent —
so a mistyped or not-yet-installed tool becomes an install/fix suggestion
instead of `zsh: command not found`. Clear shell syntax (paths, pipes,
redirects, `VAR=value`) stays with the shell even when a token is missing.
Aliases and shell functions are invisible to the pre-check; **Cmd+Return**
forces shell. Routing only occurs at a ready zsh prompt. Input to a
foreground command, REPL, or other program always goes to that program.

Open **Agent** in the chrome bar or sidebar, use **Agent → Open Agent**, or press
**Cmd+Shift+A** to open the inline Agent panel without submitting terminal text.
After an agent turn, that tab's sidebar title becomes the first question (for
example `Find the largest files`) with an agent icon so sessions stay
distinguishable; shell tabs still show the folder name or last command.
Agent starts disabled. Select a provider, open
Setup, enable Agent, and configure credentials and a model:

| Provider | Authentication | Default model |
| --- | --- | --- |
| OpenAI API | OpenAI API key | `gpt-5.4-mini` |
| Codex | Installed Codex CLI/app, ChatGPT sign-in | Account default (blank model field) |
| Anthropic API | Anthropic API key | `claude-sonnet-4-6` |
| Vercel AI Gateway | Vercel AI Gateway key | `openai/gpt-5.4` |
| Grok (xAI) | xAI API key | `grok-4.6` |

Model IDs are editable; Gateway uses `provider/model` IDs. API keys are saved
from secure fields to Keychain. **Return** sends a follow-up from the Ask
composer. **Stop**, disabling AI, closing Sora, or switching providers cancels
the current answer.
Partial answers stay visible. Copy copies text without executing anything.
Standard Edit commands target the focused native field or terminal.

Switching providers restores that provider's own conversation, draft, and model.
Conversations are not transferred between services. Only explicitly entered Ask
text and prior completed Ask turns are sent. There is no automatic terminal,
repository, working-directory, environment, or command-history collection.
The local classifier makes no AI calls. A terminal sentence is sent only after
the **↵ agent** label appears and the user presses Return. Sora classifies the
line zsh actually holds, mirrored from its ZLE buffer, so clicks, arrow keys,
history recall, completion, and paste cannot desync routing. This is what keeps
conversational requests containing URLs with `?` from reaching the shell, where
zsh would fail to glob them.

### Persistent agent actions

When a typed line routes to the agent, zsh closes the block the same way it
closes a command run, labelled `(agent)` instead of a duration. Sora sends
Ctrl+6 through `ghostty_surface_key`; Ghostty encodes that as ASCII RS
(0x1E), which `command-blocks.zsh` binds to the handoff widget. A bare RS
codepoint writes nothing to the PTY (Ghostty only emits C0 via ctrlSeq), and
`ghostty_surface_text` is bracketed paste so a Unicode sentinel tried earlier
was inserted as a visible diamond and never ran the widget. The widget only
raises a flag and calls `send-break`, leaving the rule to `precmd`, because
printing from inside a widget desynchronizes ZLE's row bookkeeping and its
redraw erases the rule. Without Sora's zsh integration loaded the app falls
back to Control-C and no rule is drawn.

Agent mode stays visible until **ESC for terminal**. Each command starts in the
active tab's directory captured when its proposal was generated. Commands use a
separate noninteractive zsh, not the user's PTY; interactive input, shell aliases,
and persistent cd/environment changes are unsupported. The runner still skips
every zsh startup file (`zsh -f` with `ZDOTDIR=/dev/null`), so no alias or
function from the user's dotfiles can change what a proposed command means.

Its search path, however, is the user's. A fixed `/usr/bin:/bin:/usr/sbin:/sbin`
made the agent blind to Homebrew, pipx, mise, and anything else installed
outside the system prefixes: it reported present tools as missing and offered to
reinstall them, which is worse than a missing answer. `LoginShellPath` asks the
user's login shell for `$PATH` once per launch (interactive first, since many
people extend PATH in `.zshrc`) and falls back to a list including both Homebrew
prefixes if the shell cannot be reached. Borrowing the search path is a
deliberate trade: a hostile entry in the user's own PATH would apply here too,
but it already applies to every command they type in the terminal.

Sora defaults to **Ask for approval**: every proposed command and webpage fetch
waits for an explicit decision. Switch to **Approve for me** to auto-run the
narrow read-only listing grammar (pwd, constrained ls/du, find -type f
-print/-print0, and constrained pipelines through xargs -0 du -h, sort, and
head); webpage fetches and anything outside that grammar still need approval.
**Full access** runs any validated proposal and fetches pages without asking.
The mode is stored in UserDefaults and can be changed from Setup or the
Agent status bar at any time. Substitutions, redirections, and shell escapes are
never treated as routine under Approve for me. Approval is persisted before
execution. This is a conservative permission check, not an OS sandbox.
Approved commands have the user's filesystem permissions.

When the agent needs a public HTTPS page, it proposes a `<SORA_WEBPAGE>` envelope.
Under Approve for me / Full access, Sora fetches a static text snapshot
automatically (no cookies, credentials, or script execution), using the same
limits as the earlier manual attach path (2 MB download, 50 KB text, HTTPS-only
public hosts). Under Ask for approval, the fetch waits for an explicit confirm.
The snapshot is stored on the conversation turn and fed back to the model as
untrusted reference data. There is no manual **Attach webpage** control in the
composer; the agent owns fetching when a page is required.

Output (up to 32 KiB), working directory, and exit code stay in the conversation
and are sent to the selected AI provider as untrusted result data. The AI reviews
results, proposes a next command or webpage when needed, or summarizes findings
and a next step. Each user turn permits at most six agent actions (commands or
webpage fetches); each command has a 60-second time limit. Stop marks the
command stopped, kills its process group, keeps Ask busy until the runner exits,
stores any captured output, and cancels continuation so a second command cannot
overlap a dying pipeline. A time limit pauses for user follow-up without treating
the pause as a user Stop. Commands are never resumed on relaunch.

Providers only propose commands and webpages through Sora's strict single-line
envelopes. Malformed envelopes and control characters are rejected. The initial
prompt handoff still uses a terminal interrupt to cancel the shell edit buffer.

### Webpage snapshots

Redirects must remain HTTPS. Unsupported encodings, binary files, large
responses, empty extracted text, HTTP errors, and timeouts are visible to the
model on the next turn. Sites that require JavaScript or sign-in may return
little readable text in this static first slice.

## Codex setup and boundaries

Install version 0.153.0 or newer of the official Codex CLI or desktop app.
**Check Sign-In** queries its Keychain-backed account status. **Sign In with
ChatGPT** opens official browser login and reports completion in Sora. Sora
does not read or copy token files. A CLI login stored only in a file requires
signing in again through this Keychain configuration. The executable is found
in Homebrew's standard bin locations or the Codex/ChatGPT application bundle.

Codex runs through the official stdio app-server, one process per Ask request
or sign-in operation. Ask uses an ephemeral thread with empty environments,
workspace roots, capability roots, and dynamic tools. Process-local settings
disable shell, hooks, plugins, apps, MCP servers, web search, host skill
discovery, and memory. It uses a temporary working directory and replaces base
instructions. Server-originated tool/approval requests are rejected. Global
Codex configuration is not edited. This is a text-only Ask adapter.

The minimum version is enforced because this configuration uses experimental
app-server environment and capability controls. JSON-RPC requests time out;
cancellation closes the process. Short replies are consumed as they arrive,
without waiting for a full pipe buffer. Stderr and raw RPC errors are not logged.

## Ownership and data

- `Agent/AIProvider.swift`: internal messages, requests, events, and errors.
  Provider-owned schemas do not cross this boundary.
- `Agent/PromptIntentClassifier.swift`: local routing between shell input and
  Ask. Catch-all uses `ShellCommandResolver` (PATH + builtins) so unknown
  commands become agent turns. No provider dependency.
- `Agent/ShellCommandResolver.swift`: resolves the primary command against the
  login-shell PATH and a fixed zsh builtin set before Return.
- `Agent/AgentCommandProposal.swift`: provider-independent proposal validation,
  strict envelope parsing, and persisted approve/dismiss state.
- `Agent/AskSession.swift`: explicit send, cancellation, completed-turn context,
  duplicate-send prevention, and request IDs that reject stale events.
- `Providers/AIBackend.swift`: provider list, defaults, destinations, and stores.
- `Providers/HTTPAIProvider.swift` and `OpenAIProvider.swift`: fixed official
  HTTPS endpoints, ephemeral URLSession transport, and distinct Responses,
  Messages, and Chat Completions streaming event decoders. Stream errors and
  truncation are surfaced; credentials and raw server errors are not logged.
- `Providers/CodexConnection.swift`, `CodexProvider.swift`, and `CodexLogin.swift`:
  local process transport, ephemeral Ask requests, and explicit browser sign-in.
- `Storage/AICredentialStore.swift`: non-synchronizing generic-password Keychain
  service `dev.sora.app.ai`, accounts `openai`, `anthropic`, `gateway`, and `grok`.
  Codex manages its own Keychain credentials. Saving updates an existing item;
  removing a key cancels any request. No secrets in UserDefaults, JSON, SQLite,
  or source control.
- `Storage/AIConversationStore.swift`: one conversation per provider under
  `~/Library/Application Support/Sora/`. OpenAI preserves `ask.json`; others use
  `ask-codex.json`, `ask-anthropic.json`, `ask-gateway.json`, and `ask-grok.json`. Writes are
  atomic with 0600 permissions. These are local plaintext files. Clear
  Conversation empties the selected provider's conversation. Interrupted
  streaming messages load as stopped. Corrupt files produce a visible error
  and are not overwritten by a send.

Initialization neither reads Keychain nor contacts the network. History loads
when Ask opens. Keychain reads occur on explicit send or Codex account setup.
Selected provider and per-provider model settings use UserDefaults; drafts stay
in memory. A failed AI setup or request cannot block the Ghostty terminal.

OpenAI requests set `store: false`; this controls Responses application-state
storage, not all provider retention policies. All HTTP adapters cap output at
4,096 tokens; Codex uses the account/model's output limits. Input over 100,000
UTF-8 bytes is rejected locally rather than silently dropping context. Failed
and stopped turns remain visible but are excluded from later provider context.

## Verification and remaining work

98 tests pass, including strict command proposal parsing, persisted one-time
approval and dismissal, conversational prompt routing, shell-command false
positives, explicit routing overrides, Unicode prompt tracking, provider and pending-attachment isolation,
keys/models/drafts, disabled and
missing-key behavior, streaming completion and cancellation, stale events,
partial-turn exclusion, persistence errors, request serialization, Unicode SSE,
HTTP auth/rate errors, truncation, and Codex RPC pipe handling and configuration.
HTTP tests use an isolated URLProtocol fixture. The Codex transport regression
uses a local shell fixture with short replies and an open stdout pipe.

Webpage tests cover URL normalization and scheme/credential rejection, static
HTML extraction and entity decoding, script/style/attribute removal, Unicode-safe
excerpt limits, download and streaming size bounds, content types, encodings,
HTTP failures, no request credentials or cookies, Codable backward compatibility,
provider payloads, context accounting, persistence failures, and late-result
rejection after cancellation.

The inline path was exercised by typing a conversational request at a ready
prompt, receiving and dismissing a live Vercel AI Gateway command proposal,
approving a separate `pwd` proposal, and observing `pwd` run in the current
Ghostty terminal. The installed Codex 0.153.0 app-server initialization and account/read handshake
were exercised locally and in the app. Provider menus, model defaults, secure
fields, and the Codex missing-sign-in state were checked manually. Vercel AI
Gateway streaming was exercised with `openai/gpt-5.4`, including a two-turn
conversation. The webpage flow fetched `https://www.elishaterada.com/`, displayed
the extracted text for review, attached it, and received a source-cited summary
from that Gateway model. Other live responses and browser login completion still
require user-supplied API keys or ChatGPT sign-in. The installed Codex currently reports
no Keychain sign-in.

The UI renders assistant answers as Markdown (headings, lists, inline code,
links) via Foundation `AttributedString`. That parser records block structure in
`presentationIntent` without emitting newlines, so `AgentMarkdown` splits runs
into `AgentMarkdownBlock` values and `AgentMarkdownText` lays each one out as its
own view; rendering the string as a single `Text` ran blocks together. Inline
code is tinted peach rather than boxed in a background fill, which kept
identifier-dense paragraphs unreadable.

Filesystem paths the agent mentions become `file://` links that reveal in
Finder, resolved against the agent working directory. A whole code span counts
as one token so paths containing spaces resolve, bare words like `ffmpeg` are
left alone even when a file of that name exists, and the target must exist so a
link never dead-ends. Fenced blocks are skipped: they hold commands to read and
copy, not references. macOS makes a selectable `Text` and a tappable link
mutually exclusive, so only blocks that contain links drop
`textSelection(.enabled)`; code blocks and link-free prose stay selectable, and
every message keeps its Copy button.

Envelope handling is deliberately tolerant, because the raw `<SORA_COMMAND>`
wire format used to reach the transcript whenever a model deviated from the
prompt. `AgentEnvelope` finds a single envelope anywhere in a reply and keeps
the surrounding prose as the answer, recovers values when a shell one-liner
leaves inner quotes unescaped and strict JSON decoding fails, and hides a
partially streamed tag behind the "Preparing a command…" status. Two envelopes
in one reply are ambiguous and are refused. When an envelope is present but
unreadable, the transcript shows the prose and the panel reports that the
request was malformed rather than printing the protocol text. Recovery never
lowers the permission bar: the command still appears in full in the approval
card, and only routine read-only commands auto-run.

The system prompt asks for scannable
GitHub-flavored Markdown on normal replies; command and webpage envelopes stay
plain. Command output remains monospace plain text with path links. There is one
conversation per provider and no transcript browser. General terminal scrollback
attachments and interactive agent commands remain future work.
Grok connects directly to `https://api.x.ai/v1/chat/completions` using Bearer
authentication. This supported legacy endpoint reuses the existing stateless
Chat Completions transport for this text-only slice. xAI recommends Responses
for newer capabilities; adopting those is separate work. The Grok timeout is
3,600 seconds to allow reasoning before the first token; Stop remains available.
Grok streaming, Unicode, authentication/rate failures, and truncated responses
are verified with local HTTP fixtures. A live Grok response still needs an xAI
key. No external dependency was added.

## Prompt editing recovery

Prompt tracking recognizes macOS control characters for Control-C and Control-U,
so cancelling or clearing a line allows the next conversational prompt to route
to Ask AI. Clicking a ready prompt (or the sticky footer) focuses the terminal
and keeps tracking, so typing `Help me find the largest files` still shows
**↵ agent** and Return opens Ask — even after a focus click. Arrow keys and
Control-A/E/K/W remain conservative: these move the cursor or delete only part
of a line, so tracking stops rather than classifying a suffix as the whole
command. History navigation and unsupported edits still require a fresh prompt
(Control-C) before automatic AI detection resumes.

## Official references

- [OpenAI Responses](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [OpenAI streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events)
- [Codex app-server](https://developers.openai.com/codex/app-server)
- [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Anthropic API](https://platform.claude.com/docs/en/api/overview)
- [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [Vercel Chat Completions](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions/rest-api)
- [Vercel model catalog](https://ai-gateway.vercel.sh/v1/models)

- [xAI Chat Completions](https://docs.x.ai/developers/model-capabilities/legacy/chat-completions)
- [xAI streaming](https://docs.x.ai/developers/model-capabilities/text/streaming)

## Keychain responsiveness

Credential reads, saves, and removals use an asynchronous interface and a serial
background queue per Keychain store. macOS can wait for approval without blocking
the terminal interface. Stop and provider changes invalidate a pending request;
a credential returned afterward cannot start that request. The macOS Keychain
operation itself cannot be cancelled. Setup shows progress and prevents duplicate
key changes while an operation is pending. Failed credential reads leave a failed
turn visible, with the error and the original question retained in the transcript.
