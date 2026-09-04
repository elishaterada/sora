# Native Ask: first AI vertical slice

Authorized on 2026-09-04 by the user's request to implement AI. This supersedes
the earlier no-AI scope restriction for this slice. It does not authorize
accounts, sync, a hosted backend, or an autonomous command runner.

## User flow

Open **AI → Ask Sora** or **Cmd+Shift+A**. AI starts disabled. Enable it in
Setup, enter your OpenAI API key in the secure field, save it, and choose a
model ID. The default is `gpt-5.4-mini`. **Cmd+Return** sends a question;
**Stop**, disabling AI, or closing Ask cancels the current request. A stopped
answer stays visible as partial text. Copy copies the answer without executing
anything. Standard Edit commands target the focused native field or terminal.

Only text explicitly entered into Ask and prior completed Ask turns are sent.
There is no automatic terminal, repository, working-directory, environment, or
command-history collection. There are no AI calls from typing in the terminal.

## Ownership and data

- `Agent/AIProvider.swift`: internal messages, requests, events, errors, and
  adapter protocol. No provider SDK schema crosses this boundary.
- `Agent/AskSession.swift`: conversation state, explicit send, cancellation,
  duplicate-send prevention, and stale-event protection using request IDs.
- `Providers/OpenAIProvider.swift`: fixed official HTTPS endpoint, ephemeral
  URLSession, text/refusal deltas, completion and failure events. Stream errors
  are surfaced. Credentials and raw server error bodies are not logged.
- `Storage/AICredentialStore.swift`: non-synchronizing generic-password Keychain
  item, service `dev.sora.app.ai`, account `openai`. Saving updates the existing
  item; removing a key cancels any in-flight request. No key in UserDefaults,
  JSON, SQLite, or source control.
- `Storage/AIConversationStore.swift`: one current conversation in
  `~/Library/Application Support/Sora/ask.json`, atomically written with 0600
  file permissions. It is local plaintext, not encrypted chat storage.
  Clear Conversation replaces it with an empty conversation. Interrupted
  streaming messages load as stopped. Corrupt files produce a visible error
  and are not overwritten by a send.

AI initialization neither reads Keychain nor contacts the network. Loading
Ask history happens only when opening Ask. Keychain reads occur on explicit
send. A failed AI setup or request cannot block the Ghostty terminal lifecycle.

The OpenAI request sets `store: false`, requests streaming text, and caps output
at 4,096 tokens. This controls Responses application-state storage, not all
provider retention policies. Input over 100,000 UTF-8 bytes is rejected locally
with a request to start a new conversation, rather than silently dropping
context. Failed and stopped turns remain visible but are excluded from later
provider context.

## Verification and remaining work

Tests cover disabled/missing-key behavior, streaming state, completion,
cancellation, stale events, partial-turn exclusion, persistence failure and
recovery, request serialization, SSE Unicode split across bytes, HTTP auth/rate
errors, malformed events, refusals, and premature stream termination. HTTP tests
use an isolated URLProtocol fixture, never a live key or paid request.

Live OpenAI account/model access still needs a user-supplied key and an actual
request. The current UI displays selectable plain text, including Markdown
source. It retains one conversation and offers no transcript browser. Automatic
context attachments, structured command cards, tools, permissions, and agent
loops are separate future slices. No external dependency was added.

## Official API references

- [Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [Streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events)
- [GPT-5.4 Mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini)
