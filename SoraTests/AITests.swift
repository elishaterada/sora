import Foundation
import XCTest

final class OpenAIProviderTests: XCTestCase {
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

    func testDisabledAndMissingKeyNeverStartNetworkRequests() {
        let provider = ControlledProvider()
        let session = makeSession(provider, key: MemoryKey(nil))
        session.draft = "Explain pwd"
        session.send()
        XCTAssertFalse(session.isSending)
        XCTAssertTrue(provider.requests.isEmpty)
        session.enabled = true
        session.send()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(session.messages.isEmpty)
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
        session.selectProvider(.anthropic)
        XCTAssertFalse(session.isSending)
        XCTAssertEqual(firstStore.messages.last?.status, .stopped)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.model, AIBackendID.anthropic.defaultModel)
        _ = session.saveKey("updated-second-key")
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
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("Prints "))
        provider.emit(.text("the directory."))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.last?.text, "Prints the directory.")
        XCTAssertEqual(store.messages.last?.status, .complete)
        session.draft = "And ls?"
        session.send()
        await waitFor { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests.last?.messages.map(\.text), ["Explain pwd", "Prints the directory.", "And ls?"])
        session.stop()
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
        session.send()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(session.draft, "keep this")
        XCTAssertNotNil(session.errorMessage)
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
