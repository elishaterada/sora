# Native Ask: optional AI providers

Authorized on 2026-09-04 by the user's requests to implement AI with OpenAI API,
Codex, Anthropic API, Vercel AI Gateway, and Grok (xAI). This supersedes the earlier no-AI
scope restriction for this slice. Accounts, sync, a hosted backend, and
an autonomous command runner remain deferred.

## User flow

At a ready shell prompt, type a clear conversational request such as
`Help me find the largest files` and press Return. Sora labels the line
**AI prompt** while typing, removes it from the shell input, and opens Ask in
the same terminal tab. **Back to Terminal** or Escape returns to the unchanged
terminal session. No separate Ask window is created.

Routing is conservative and local. Known command names, executable paths,
assignments, shell operators, short input, and ambiguous text remain shell
input. Press **Cmd+Return** to force a detected sentence to run in the shell.
Start a line with `/agent ` to force command-like text to AI; the prefix is
removed before sending. Routing only occurs at a ready zsh prompt. Input to a
foreground command, REPL, or other program always goes to that program.

Open **AI → Ask Sora** or press **Cmd+Shift+A** to open the inline Ask panel
without submitting terminal text. AI starts disabled. Select a provider, open
Setup, enable AI, and configure credentials and a model:

| Provider | Authentication | Default model |
| --- | --- | --- |
| OpenAI API | OpenAI API key | `gpt-5.4-mini` |
| Codex | Installed Codex CLI/app, ChatGPT sign-in | Account default (blank model field) |
| Anthropic API | Anthropic API key | `claude-sonnet-4-6` |
| Vercel AI Gateway | Vercel AI Gateway key | `openai/gpt-5.4` |
| Grok (xAI) | xAI API key | `grok-4.6` |

Model IDs are editable; Gateway uses `provider/model` IDs. API keys are saved
from secure fields to Keychain. **Cmd+Return** sends a question from the Ask
composer. **Stop**, disabling AI, closing Sora, or switching providers cancels
the current answer.
Partial answers stay visible. Copy copies text without executing anything.
Standard Edit commands target the focused native field or terminal.

Switching providers restores that provider's own conversation, draft, and model.
Conversations are not transferred between services. Only explicitly entered Ask
text and prior completed Ask turns are sent. There is no automatic terminal,
repository, working-directory, environment, or command-history collection.
The local classifier makes no AI calls. A terminal sentence is sent only after
the **AI prompt** label appears and the user presses Return.

### Attach webpage

Choose **Attach webpage**, enter a public HTTPS address (typing a hostname adds
`https://`), and choose **Fetch Page**. This contacts the website without saved
cookies or credentials, downloads at most 2 MB, and accepts HTML or plain text.
HTML is never rendered and page scripts or subresources are never run or loaded.
Script, style, template, SVG, head, comments, and markup are removed to create a
static text snapshot. The preview is the exact text that can be attached.

Readable text is capped at 50,000 UTF-8 bytes on a Unicode scalar boundary and
is labeled as an excerpt when capped. Review it, then choose **Attach to
Question**. The page title/host appears beside the composer; Review and Remove
remain available until sending. The attachment is not sent on fetch or attach.
It is sent with the next question only, stored with that user message, and shown
in an expandable conversation disclosure afterward. Switching providers keeps
unsent attachments isolated with that provider, and clearing its conversation
also clears its pending attachment.

The model receives the question plus a JSON snapshot labeled as external
reference data, including URL, title, fetch time, excerpt flag, and text. System
instructions require providers to treat embedded page content as untrusted data,
cite the source URL, and avoid inventing missing content. Redirects must remain
HTTPS. Unsupported encodings, binary files, large responses, empty extracted
text, HTTP errors, and timeouts are visible to the user. Sites that require
JavaScript or sign-in may return little readable text in this static first slice.

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
- `Agent/PromptIntentClassifier.swift`: local conservative routing between
  shell input and an explicit Ask submission. It has no provider dependency.
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

95 tests pass, including conversational prompt routing, shell-command false
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
prompt, streaming a live Vercel AI Gateway answer in the same tab, returning to
a clean prompt, and running `pwd` normally. The installed Codex 0.153.0 app-server initialization and account/read handshake
were exercised locally and in the app. Provider menus, model defaults, secure
fields, and the Codex missing-sign-in state were checked manually. Vercel AI
Gateway streaming was exercised with `openai/gpt-5.4`, including a two-turn
conversation. The webpage flow fetched `https://www.elishaterada.com/`, displayed
the extracted text for review, attached it, and received a source-cited summary
from that Gateway model. Other live responses and browser login completion still
require user-supplied API keys or ChatGPT sign-in. The installed Codex currently reports
no Keychain sign-in.

The router does not grant tools or execute generated commands. The UI displays selectable plain text, including Markdown source. There is one
conversation per provider and no transcript browser. Terminal context attachments,
command cards, tools, permissions, and agent loops are future slices.
Grok connects directly to `https://api.x.ai/v1/chat/completions` using Bearer
authentication. This supported legacy endpoint reuses the existing stateless
Chat Completions transport for this text-only slice. xAI recommends Responses
for newer capabilities; adopting those is separate work. The Grok timeout is
3,600 seconds to allow reasoning before the first token; Stop remains available.
Grok streaming, Unicode, authentication/rate failures, and truncated responses
are verified with local HTTP fixtures. A live Grok response still needs an xAI
key. No external dependency was added.

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
