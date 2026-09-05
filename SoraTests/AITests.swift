import Foundation
import XCTest

final class OpenAIProviderTests: XCTestCase {
    func testCommandProposalEnvelopeIsStrictAndSingleLine() throws {
        let valid = #"<SORA_COMMAND>{"summary":"List the largest files without changing them.","command":"find . -type f -print | head"}</SORA_COMMAND>"#
        XCTAssertEqual(
            AgentCommandProposalParser.parse(valid),
            AgentCommandProposal(
                summary: "List the largest files without changing them.",
                command: "find . -type f -print | head"
            )
        )
        XCTAssertTrue(AgentCommandProposalParser.isStreamingEnvelope("<SORA_"))
        XCTAssertTrue(AgentCommandProposalParser.isStreamingEnvelope("<SORA_COMMAND>{"))
        XCTAssertNil(AgentCommandProposalParser.parse("Run this:\n\(valid)"))
        XCTAssertNil(AgentCommandProposalParser.parse(#"<SORA_COMMAND>{"summary":"Run it","command":"pwd\nwhoami"}</SORA_COMMAND>"#))
        XCTAssertNil(AgentCommandProposalParser.parse(#"<SORA_COMMAND>{"summary":"","command":"pwd"}</SORA_COMMAND>"#))
        XCTAssertFalse(AgentCommandProposal.isValidCommand("pwd\u{1B}"))
        XCTAssertFalse(AgentCommandProposal.isValidCommand("echo safe\u{202E}txt"))
    }

    func testGrokRequestUsesDirectXAIEndpointAndExplicitConversation() throws {
        let request = AIRequest(model: AIBackendID.grok.defaultModel,
                                messages: [AIMessage(role: .user, text: "Explain pwd")])
        let http = try HTTPAIProvider.urlRequest(kind: .grok, request: request, credential: "xai-fixture-key")
        XCTAssertEqual(http.url?.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Authorization"), "Bearer xai-fixture-key")
        XCTAssertNil(http.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(http.timeoutInterval, 3600)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: http.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "grok-4.6")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(body["messages"] as? [[String: String]], [
            ["role": "system", "content": AIRequest.instructions],
            ["role": "user", "content": "Explain pwd"]
        ])
        XCTAssertNil(body["tools"])
        XCTAssertFalse(String(decoding: http.httpBody!, as: UTF8.self).contains("xai-fixture-key"))
    }

    func testGrokStreamsUnicodeAndSurfacesHTTPAndIncompleteResponses() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = HTTPAIProvider(kind: .grok, session: session)
        let request = AIRequest(model: "grok-4.6", messages: [AIMessage(role: .user, text: "hello")])
        var events: [AIEvent] = []
        for try await event in provider.events(for: request, credential: "fixture-success") { events.append(event) }
        XCTAssertEqual(events, [.text("Hello 猫"), .completed])
        for mode in ["fixture-401", "fixture-429", "fixture-eof", "fixture-length"] {
            do {
                for try await _ in provider.events(for: request, credential: mode) {}
                XCTFail("Expected a visible failure for \(mode)")
            } catch { XCTAssertTrue(error is AIError) }
        }
    }

    func testProviderSpecificEndpointsHeadersAndPayloads() throws {
        let request = AIRequest(model: "test-model", messages: [AIMessage(role: .user, text: "Explain pwd")])
        let anthropic = try HTTPAIProvider.urlRequest(kind: .anthropic, request: request, credential: "anthropic-key")
        XCTAssertEqual(anthropic.url?.host, "api.anthropic.com")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: anthropic.httpBody!) as? [String: Any])
        XCTAssertNotNil(body["system"])
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        let gateway = try HTTPAIProvider.urlRequest(kind: .gateway, request: request, credential: "gateway-key")
        XCTAssertEqual(gateway.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/chat/completions")
        XCTAssertEqual(gateway.value(forHTTPHeaderField: "Authorization"), "Bearer gateway-key")
        XCTAssertNil(gateway.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertFalse(String(decoding: gateway.httpBody!, as: UTF8.self).contains("gateway-key"))
    }

    func testAnthropicStreamingCompletionAndTruncation() throws {
        var parser = ProviderStreamDecoder(kind: .anthropic)
        XCTAssertEqual(try parser.parse(line: "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}"), [.text("Hi")])
        XCTAssertEqual(try parser.parse(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"), [])
        XCTAssertEqual(try parser.parse(line: "data: {\"type\":\"message_stop\"}"), [.completed])
        var truncated = ProviderStreamDecoder(kind: .anthropic)
        XCTAssertThrowsError(try truncated.parse(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"))
        XCTAssertThrowsError(try truncated.parse(line: "data: {\"type\":\"message_stop\"}"))
        XCTAssertThrowsError(try truncated.parse(line: "data: {\"type\":\"error\",\"error\":{}}"))
    }

    func testGatewayRequiresFinishReasonBeforeDone() throws {
        var parser = ProviderStreamDecoder(kind: .gateway)
        XCTAssertEqual(try parser.parse(line: "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}"), [.text("hello")])
        XCTAssertThrowsError(try parser.parse(line: "data: [DONE]"))
        XCTAssertEqual(try parser.parse(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"), [])
        XCTAssertEqual(try parser.parse(line: "data: [DONE]"), [.completed])
        XCTAssertThrowsError(try parser.parse(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}"))
    }

    func testURLSessionStreamingAndHTTPFailuresWithoutNetwork() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = OpenAIProvider(session: session)
        let request = AIRequest(model: "test", messages: [AIMessage(role: .user, text: "hello")])
        var events: [AIEvent] = []
        for try await event in provider.events(for: request, credential: "fixture-success") { events.append(event) }
        XCTAssertEqual(events, [.text("Hello 猫"), .completed])
        for mode in ["fixture-401", "fixture-429", "fixture-eof"] {
            do {
                for try await _ in provider.events(for: request, credential: mode) {}
                XCTFail("Expected a visible failure for \(mode)")
            } catch {
                XCTAssertTrue(error is AIError)
            }
        }
    }

    func testRequestContainsOnlyExplicitConversationAndDisablesRemoteStorage() throws {
        let request = try OpenAIProvider.urlRequest(
            AIRequest(model: "test-model", messages: [AIMessage(role: .user, text: "Explain ls")]),
            credential: "test-key"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["input"] as? [[String: String]], [["role": "user", "content": "Explain ls"]])
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-key"))
    }

    func testStreamingTextRefusalsErrorsAndCompletion() throws {
        XCTAssertEqual(try OpenAIProvider.parse(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 猫\"}"), .text("Hello 猫"))
        XCTAssertEqual(try OpenAIProvider.parse(line: "data: {\"type\":\"response.refusal.delta\",\"delta\":\"No\"}"), .text("No"))
        XCTAssertEqual(try OpenAIProvider.parse(line: "data: {\"type\":\"response.completed\"}"), .completed)
        XCTAssertNil(try OpenAIProvider.parse(line: "event: response.created"))
        XCTAssertNil(try OpenAIProvider.parse(line: ": keepalive"))
        XCTAssertNil(try OpenAIProvider.parse(line: "data: {\"type\":\"response.created\"}"))
        for line in ["data: invalid", "data: {\"type\":\"response.failed\"}",
                     "data: {\"type\":\"response.incomplete\"}", "data: {\"type\":\"error\"}"] {
            XCTAssertThrowsError(try OpenAIProvider.parse(line: line))
        }
    }
}

/// Intercepts only this test's URLSession. No production endpoint or credential
/// is used; splitting every UTF-8 byte exercises the actual async line reader.
private final class AIHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let status = mode.hasSuffix("401") ? 401 : mode.hasSuffix("429") ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var body = "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 猫\"}\r\n\r\n"
        if !mode.hasSuffix("eof") { body += "data: {\"type\":\"response.completed\"}\n\n" }
        if request.url?.host == "api.x.ai" {
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello 猫\"},\"finish_reason\":null}]}\r\n\r\n"
            if !mode.hasSuffix("eof") {
                let reason = mode.hasSuffix("length") ? "length" : "stop"
                body += "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n\ndata: [DONE]\n\n"
            }
        }
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AskSessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "SoraAskTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeSession(_ provider: ControlledProvider = ControlledProvider(),
                             key: MemoryKey = MemoryKey(), store: MemoryConversation = MemoryConversation()) -> AskSession {
        AskSession(provider: provider, credentials: key, conversations: store, defaults: defaults)
    }

    func testAgentRunsCommandAndFeedsOutputBackBeforeSummarizing() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.configureAgent(directory: URL(fileURLWithPath: "/private/tmp"))
        session.draft = "Show me the current directory"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("<SORA_COMMAND>{\"summary\":\"Read directory\",\"command\":\"pwd\"}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { provider.requests.count == 2 }
        let result = session.messages.compactMap(\.commandResult).first
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertTrue(result?.output.contains("/private/tmp") == true)
        XCTAssertTrue((try? provider.requests.last?.messages.map { try $0.contentForProvider() }.joined().contains("Command result")) == true)
        provider.emit(.text("The directory is /private/tmp. Next, list its contents."))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertFalse(session.isRunningCommand)
        XCTAssertTrue(session.messages.last?.text.contains("Next") == true)
    }

    func testAgentFeedsFailureBackAndStopsAtCommandLimit() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.configureAgent(directory: URL(fileURLWithPath: "/private/tmp"))
        session.draft = "Help me inspect files"
        session.send()
        for step in 1...6 {
            await waitFor { provider.requests.count == step }
            let command = step == 1 ? "ls /sora-test-nonexistent-directory" : "pwd"
            provider.emit(.text("<SORA_COMMAND>{\"summary\":\"Inspect files\",\"command\":\"" + command + "\"}</SORA_COMMAND>"))
            provider.emit(.completed)
            provider.finish()
        }
        await waitFor { provider.requests.count == 7 }
        XCTAssertNotEqual(session.messages.compactMap(\.commandResult).first?.exitCode, 0)
        provider.emit(.text("<SORA_COMMAND>{\"summary\":\"Inspect again\",\"command\":\"pwd\"}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.compactMap(\.commandResult).count, 6)
        XCTAssertTrue(session.errorMessage?.contains("six commands") == true)
        XCTAssertFalse(session.isRunningCommand)
    }

    func testAutomaticCommandPolicyRejectsShellEscapesAndMutations() {
        for command in ["pwd", "ls -lah", "du -sh .", "find . -type f -print0 | xargs -0 du -h | sort -hr | head -20"] {
            XCTAssertTrue(AgentCommandPermission.allowsAutomatically(command), command)
        }
        for command in ["rm file", "find . -delete", "find . -exec rm {} +", "ls; rm file", "ls $(touch file)", "ls > file", "xargs sh", "ls | xargs sh", "ls\npwd", "curl example.com", "ls --help"] {
            XCTAssertFalse(AgentCommandPermission.allowsAutomatically(command), command)
        }
    }

    func testRunnerCapturesFailuresBoundsOutputAndStopsPipelines() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp")
        let failed = try await AgentCommandRunner().run(command: "printf failure >&2; exit 7", directory: directory)
        XCTAssertEqual(failed.exitCode, 7)
        XCTAssertEqual(failed.output, "failure")
        let bounded = try await AgentCommandRunner().run(command: "yes text | head -10000", directory: directory)
        XCTAssertTrue(bounded.truncated)
        XCTAssertLessThanOrEqual(bounded.output.utf8.count, 32_768)
        let timed = try await AgentCommandRunner().run(command: "sleep 30 | cat", directory: directory, timeout: 0.1)
        XCTAssertTrue(timed.interrupted)
        XCTAssertNotEqual(timed.exitCode, 0)
    }

    func testCancelKillsPipelineWithoutWaitingForTimeout() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp")
        let runner = AgentCommandRunner()
        let task = Task {
            try await runner.run(command: "sleep 30 | cat", directory: directory, timeout: 60)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.cancel()
        let result = try await task.value
        XCTAssertTrue(result.interrupted)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testStopDuringAgentCommandKillsPipelineAndSkipsContinuation() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.configureAgent(directory: URL(fileURLWithPath: "/private/tmp"))
        session.draft = "Sleep for a while"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("<SORA_COMMAND>{\"summary\":\"Wait briefly\",\"command\":\"sleep 30 | cat\"}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor {
            !session.isSending && session.messages.last?.commandProposal?.status == .pending
        }
        guard let messageID = session.messages.last?.id else {
            return XCTFail("Missing command proposal")
        }
        session.runCommand(messageID: messageID)
        await waitFor { session.isRunningCommand }
        // Give posix_spawn a moment so Stop exercises process-group kill, not
        // only the pre-spawn cancellation path.
        try? await Task.sleep(nanoseconds: 100_000_000)
        session.stop()
        XCTAssertEqual(session.messages.last?.commandState, "stopped")
        XCTAssertTrue(session.isRunningCommand)
        await waitFor { !session.isRunningCommand }
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(session.messages.last?.commandState, "stopped")
        XCTAssertEqual(session.messages.last?.commandResult?.interrupted, true)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.isSending)
    }

    func testImmediateStopBeforeSpawnStillRecordsInterruptedResult() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.configureAgent(directory: URL(fileURLWithPath: "/private/tmp"))
        session.draft = "Sleep for a while"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("<SORA_COMMAND>{\"summary\":\"Wait briefly\",\"command\":\"sleep 30 | cat\"}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor {
            !session.isSending && session.messages.last?.commandProposal?.status == .pending
        }
        guard let messageID = session.messages.last?.id else {
            return XCTFail("Missing command proposal")
        }
        session.runCommand(messageID: messageID)
        session.stop()
        await waitFor { !session.isRunningCommand }
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(session.messages.last?.commandResult?.interrupted, true)
        XCTAssertEqual(session.messages.last?.commandState, "stopped")
    }

    func testTerminalAgentStartsFreshAndTabsKeepSeparateTranscripts() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        let first = UUID(), second = UUID()

        session.bindTab(first)
        session.beginTerminalAgent(question: "Help me find the largest files", directory: URL(fileURLWithPath: "/private/tmp"))
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("First tab answer"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.first?.text, "Help me find the largest files")
        XCTAssertEqual(session.messages.last?.text, "First tab answer")

        session.bindTab(second)
        XCTAssertTrue(session.messages.isEmpty)
        session.beginTerminalAgent(question: "Explain pwd", directory: URL(fileURLWithPath: "/private/tmp"))
        await waitFor { provider.requests.count == 2 }
        provider.emit(.text("Second tab answer"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.first?.text, "Explain pwd")
        XCTAssertEqual(session.messages.count, 2)

        session.beginTerminalAgent(question: "Fresh question", directory: URL(fileURLWithPath: "/private/tmp"))
        await waitFor { provider.requests.count == 3 }
        XCTAssertEqual(session.messages.filter { $0.role == .user }.map(\.text), ["Fresh question"])
        provider.emit(.text("Fresh answer"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }

        session.bindTab(first)
        XCTAssertEqual(session.messages.first?.text, "Help me find the largest files")
        XCTAssertEqual(session.messages.last?.text, "First tab answer")
        session.discardTab(first)
        XCTAssertTrue(session.messages.isEmpty)
    }

    func testStopWhileWaitingForKeychainPreventsLateNetworkRequest() async {
        let key = DelayedKey()
        let provider = ControlledProvider()
        let session = AskSession(provider: provider, credentials: key,
                                 conversations: MemoryConversation(), defaults: defaults)
        session.enabled = true
        session.draft = "Help me find large files"
        session.send()
        await waitFor { key.continuation != nil }
        XCTAssertTrue(session.isSending)
        // This runs on the main actor while credential access is still pending.
        session.stop()
        XCTAssertFalse(session.isSending)
        XCTAssertEqual(session.messages.last?.status, .stopped)
        key.continuation?.resume(returning: "test-key")
        key.continuation = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(session.messages.last?.status, .stopped)
    }

    func testDisabledAndMissingKeyNeverStartNetworkRequests() async {
        let provider = ControlledProvider()
        let session = makeSession(provider, key: MemoryKey(nil))
        session.draft = "Explain pwd"
        session.send()
        XCTAssertFalse(session.isSending)
        XCTAssertTrue(provider.requests.isEmpty)
        session.enabled = true
        session.send()
        XCTAssertTrue(provider.requests.isEmpty)
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.last?.status, .failed)
        XCTAssertEqual(session.errorMessage, AIError.missingKey.localizedDescription)
    }

    func testSwitchingProvidersIsolatesCredentialsModelsDraftsAndConversations() async {
        let first = ControlledProvider(), second = ControlledProvider()
        let firstKey = MemoryKey("first-key"), secondKey = MemoryKey("second-key")
        let firstStore = MemoryConversation(), secondStore = MemoryConversation()
        let backends = [AIBackend(id: .openai, provider: first, credentials: firstKey, conversations: firstStore),
                        AIBackend(id: .anthropic, provider: second, credentials: secondKey, conversations: secondStore)]
        let session = AskSession(backends: backends, defaults: defaults)
        session.enabled = true
        session.model = "openai-model"
        session.draft = "private OpenAI question"
        session.send()
        await waitFor { first.requests.count == 1 }
        first.emit(.text("partial"))
        await waitFor { session.messages.last?.text == "partial" }
        session.draft = "OpenAI draft"
        let page = WebpageAttachment(url: URL(string: "https://example.com")!, title: "Example", text: "Private page snapshot", fetchedAt: Date(), isExcerpt: false)
        session.stop()
        session.attachWebpage(page)
        session.selectProvider(.anthropic)
        XCTAssertNil(session.webpage)
        XCTAssertFalse(session.isSending)
        XCTAssertEqual(firstStore.messages.last?.status, .stopped)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.model, AIBackendID.anthropic.defaultModel)
        _ = await session.saveKey("updated-second-key")
        XCTAssertEqual(firstKey.value, "first-key")
        XCTAssertEqual(secondKey.value, "updated-second-key")
        session.draft = "Anthropic question"
        session.send()
        await waitFor { second.requests.count == 1 }
        XCTAssertEqual(second.requests.first?.messages.map(\.text), ["Anthropic question"])
        first.emit(.text("late OpenAI text"))
        first.finish()
        session.selectProvider(.openai)
        XCTAssertEqual(session.draft, "OpenAI draft")
        XCTAssertEqual(session.webpage, page)
        XCTAssertEqual(session.model, "openai-model")
        XCTAssertEqual(session.messages.last?.text, "partial")
    }

    func testCodexAllowsDefaultModelAndDoesNotRequireAPIKey() async {
        let provider = ControlledProvider()
        let session = AskSession(backends: [AIBackend(id: .codex, provider: provider,
            credentials: MemoryKey(nil), conversations: MemoryConversation())], defaults: defaults)
        session.enabled = true
        session.draft = "Codex question"
        XCTAssertEqual(session.model, "")
        session.send()
        await waitFor { provider.requests.count == 1 }
        XCTAssertTrue(session.isSending)
        session.stop()
    }

    func testStreamsPersistsAndIncludesCompletedConversationInNextTurn() async throws {
        let provider = ControlledProvider()
        let store = MemoryConversation()
        let session = makeSession(provider, store: store)
        session.enabled = true
        session.draft = "Explain pwd"
        let page = WebpageAttachment(url: URL(string: "https://example.com")!, title: "Example", text: "Reference text", fetchedAt: Date(), isExcerpt: false)
        session.attachWebpage(page)
        XCTAssertTrue(provider.requests.isEmpty)
        session.send()
        await waitFor { provider.requests.count == 1 }
        XCTAssertNil(session.webpage)
        XCTAssertEqual(provider.requests.first?.messages.first?.webpage, page)
        provider.emit(.text("Prints "))
        provider.emit(.text("the directory."))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.last?.text, "Prints the directory.")
        XCTAssertEqual(store.messages.last?.status, .complete)
        XCTAssertEqual(store.messages.first?.webpage, page)
        session.draft = "And ls?"
        session.send()
        await waitFor { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests.last?.messages.map(\.text), ["Explain pwd", "Prints the directory.", "And ls?"])
        XCTAssertEqual(provider.requests.last?.messages.first?.webpage, page)
        session.stop()
    }

    func testCommandProposalRequiresPersistedApprovalAndCannotRunTwice() async throws {
        let provider = ControlledProvider()
        let store = MemoryConversation()
        let session = makeSession(provider, store: store)
        session.enabled = true
        session.draft = "Help me find large files"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text(#"<SORA_COMMAND>{"summary":"Scan this folder read-only.","command":"find . -type f | head"}</SORA_COMMAND>"#))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }

        let message = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(message.text, "Scan this folder read-only.")
        XCTAssertEqual(message.commandProposal?.status, .pending)
        XCTAssertEqual(message.commandProposal?.command, "find . -type f | head")

        store.failSave = true
        XCTAssertNil(session.approveCommand(messageID: message.id))
        XCTAssertEqual(session.messages.last?.commandProposal?.status, .pending)
        store.failSave = false
        let approved = try XCTUnwrap(session.approveCommand(messageID: message.id))
        XCTAssertEqual(approved.status, .approved)
        XCTAssertEqual(store.messages.last?.commandProposal?.status, .approved)
        XCTAssertNil(session.approveCommand(messageID: message.id))
    }

    func testCommandProposalDismissalIsPersisted() async throws {
        let provider = ControlledProvider()
        let store = MemoryConversation()
        let session = makeSession(provider, store: store)
        session.enabled = true
        session.draft = "Show disk usage"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text(#"<SORA_COMMAND>{"summary":"Show disk usage.","command":"du -sh ."}</SORA_COMMAND>"#))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        let id = try XCTUnwrap(session.messages.last?.id)
        session.dismissCommand(messageID: id)
        XCTAssertEqual(session.messages.last?.commandProposal?.status, .dismissed)
        XCTAssertEqual(store.messages.last?.commandProposal?.status, .dismissed)
    }

    func testStopRejectsLateEventsAndNewTurnExcludesPartialAnswer() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.draft = "first"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("partial"))
        await waitFor { session.messages.last?.text == "partial" }
        session.stop()
        provider.emit(.text("late text"))
        provider.finish()
        XCTAssertEqual(session.messages.last?.status, .stopped)
        session.draft = "second"
        session.send()
        await waitFor { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests.last?.messages.map(\.text), ["second"])
        XCTAssertEqual(session.messages[1].text, "partial")
        session.enabled = false
        XCTAssertFalse(session.isSending)
        XCTAssertEqual(session.messages.last?.status, .stopped)
    }

    func testPrematureEOFIsVisibleFailure() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.draft = "question"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.last?.status, .failed)
        XCTAssertNotNil(session.errorMessage)
    }

    func testPersistenceFailureDoesNotSendOrDiscardDraft() {
        let provider = ControlledProvider()
        let store = MemoryConversation()
        store.failSave = true
        let session = makeSession(provider, store: store)
        session.enabled = true
        session.draft = "keep this"
        let page = WebpageAttachment(url: URL(string: "https://example.com")!, title: "Example", text: "Reference text", fetchedAt: Date(), isExcerpt: false)
        session.attachWebpage(page)
        session.send()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(session.draft, "keep this")
        XCTAssertEqual(session.webpage, page)
        XCTAssertNotNil(session.errorMessage)
    }

    func testAttachmentCountsTowardContextLimit() {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.draft = "Summarize"
        let page = WebpageAttachment(url: URL(string: "https://example.com")!, title: "Large", text: String(repeating: "a", count: 100_000), fetchedAt: Date(), isExcerpt: false)
        session.attachWebpage(page)
        session.send()
        XCTAssertEqual(session.errorMessage, AIError.contextTooLarge.localizedDescription)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(session.webpage, page)
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

final class CodexProviderTests: XCTestCase {
    func testShortRPCRepliesArriveWhileServerKeepsPipeOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("codex-fixture")
        let source = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) printf '%s\n' '{"id":1,"result":{"userAgent":"codex/0.153.0"}}' ;;
            *'account'*) printf '%s\n' '{"id":2,"result":{"account":null}}' ;;
          esac
        done
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let connection = CodexConnection()
        let timeout = Task {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            connection.close(CodexError.timedOut)
        }
        defer { timeout.cancel(); connection.close() }
        try await connection.start(executable: script)
        let account = try await connection.rpc("account/read", ["refreshToken": false])
        XCTAssertTrue(account["account"] is NSNull)
    }

    func testCodexAskUsesAnEphemeralThreadWithoutEnvironmentOrTools() throws {
        let params = CodexProvider.threadParameters(model: "")
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual((params["environments"] as? [String])?.count, 0)
        XCTAssertEqual((params["dynamicTools"] as? [String])?.count, 0)
        XCTAssertNil(params["model"])
        XCTAssertEqual(CodexProvider.threadParameters(model: "chosen")["model"] as? String, "chosen")
        XCTAssertTrue(CodexConnection.arguments.contains("features.hooks=false"))
        XCTAssertTrue(CodexConnection.arguments.contains("features.shell_tool=false"))
        XCTAssertTrue(CodexConnection.arguments.contains("cli_auth_credentials_store=\"keyring\""))
        XCTAssertTrue(CodexConnection.supports("Codex Desktop/0.153.0 (Mac OS 26.6.2)"))
        XCTAssertFalse(CodexConnection.supports("codex/0.100.0"))
        XCTAssertFalse(CodexConnection.supports("unknown"))
    }

    func testCodexTranslatesOnlyAnswerAndTurnCompletionEvents() throws {
        XCTAssertEqual(try CodexProvider.event(["method": "item/agentMessage/delta", "params": ["delta": "Hi"]]), .text("Hi"))
        XCTAssertNil(try CodexProvider.event(["method": "item/reasoning/textDelta", "params": ["delta": "private"]]))
        XCTAssertEqual(try CodexProvider.event(["method": "turn/completed", "params": ["turn": ["status": "completed"]]]), .completed)
        XCTAssertThrowsError(try CodexProvider.event(["method": "turn/completed", "params": ["turn": ["status": "failed"]]]))
    }
}

final class AIConversationStoreTests: XCTestCase {
    func testRoundTripAndInterruptedResponseRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SoraAsk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAIConversationStore(url: root.appendingPathComponent("ask.json"))
        XCTAssertEqual(try store.load(), [])
        let messages = [AIMessage(role: .user, text: "hello"), AIMessage(role: .assistant, text: "partial", status: .streaming)]
        try store.save(messages)
        let restored = try store.load()
        XCTAssertEqual(restored.first, messages.first)
        XCTAssertEqual(restored.last?.status, .stopped)
        try store.save([])
        XCTAssertEqual(try store.load(), [])
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }
}

private final class MemoryKey: AICredentialStore {
    var value: String?
    init(_ value: String? = "test-key") { self.value = value }
    func read() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
    func delete() throws { value = nil }
}

private final class MemoryConversation: AIConversationStore {
    var messages: [AIMessage] = []
    var failSave = false
    func load() throws -> [AIMessage] { messages }
    func save(_ messages: [AIMessage]) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        self.messages = messages
    }
}

private final class ControlledProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AIRequest] = []
    private var continuation: AsyncThrowingStream<AIEvent, Error>.Continuation?
    var requests: [AIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func events(for request: AIRequest, credential: String) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            self.continuation = continuation
        }
    }
    func emit(_ event: AIEvent) { lock.lock(); defer { lock.unlock() }; continuation?.yield(event) }
    func finish() { lock.lock(); defer { lock.unlock() }; continuation?.finish() }
}

private final class DelayedKey: AICredentialStore {
    var continuation: CheckedContinuation<String?, Error>?
    func read() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func save(_ value: String) throws {}
    func delete() throws {}
}
