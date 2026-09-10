import Foundation
import XCTest

final class OpenAIProviderTests: XCTestCase {
    func testImagesAreEmbeddedForEveryProviderAndSurvivePersistence() throws {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        let image = AIImageAttachment(name: "reference.png", png: bytes)
        let message = AIMessage(role: .user, text: "Describe", images: [image])
        let restored = try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.images?.first?.png, bytes)
        let request = AIRequest(model: "test", messages: [message])
        for kind in [AIBackendID.openai, .anthropic, .gateway, .grok] {
            let request = try HTTPAIProvider.urlRequest(kind: kind, request: request, credential: "fixture")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try XCTUnwrap(body[kind == .openai ? "input" : "messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 2)
            if kind == .anthropic {
                XCTAssertEqual((parts[1]["source"] as? [String: Any])?["data"] as? String, bytes.base64EncodedString())
            } else if kind == .openai {
                XCTAssertEqual(parts[1]["image_url"] as? String, image.dataURL)
            } else {
                XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String, image.dataURL)
            }
        }
        let input = try CodexProvider.input(request)
        XCTAssertEqual(input.last?["type"] as? String, "image")
        XCTAssertEqual(input.last?["url"] as? String, image.dataURL)
        let legacy = AIMessage(role: .user, text: "No image")
        XCTAssertNil(try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(legacy)).images)
    }

    func testProviderErrorsExplainQuotaAndRateLimitsSeparately() {
        let quota = ProviderAPIError.parse(provider: "OpenAI", status: 429, object: ["error": ["code": "insufficient_quota"]]).localizedDescription
        XCTAssertTrue(quota.contains("credits or spending limit"))
        let rate = ProviderAPIError.parse(provider: "OpenAI", status: 429, retryAfter: "12").localizedDescription
        XCTAssertTrue(rate.contains("Retry in 12 seconds"))
        XCTAssertFalse(rate.contains("exhausted"))
    }

    func testStreamingOutputLimitsAreActionable() throws {
        XCTAssertThrowsError(try OpenAIProvider.parse(line: #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("output-token limit"))
        }
        var decoder = ProviderStreamDecoder(kind: .anthropic)
        XCTAssertThrowsError(try decoder.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("output-token limit"))
        }
        var gateway = ProviderStreamDecoder(kind: .gateway)
        XCTAssertThrowsError(try gateway.parse(line: #"data: {"choices":[{"finish_reason":"length"}]}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("output-token limit"))
        }
    }

    func testAPIErrorsCoverAccessContextAndServerWithoutLeakingBody() {
        for (status, word) in [(401, "Authentication"), (403, "Access denied"), (404, "not found"), (413, "input limit"), (503, "overloaded"), (400, "invalid")] {
            XCTAssertTrue(ProviderAPIError.parse(provider: "Test", status: status).localizedDescription.contains(word))
        }
        let error = ProviderAPIError.parse(provider: "Test", status: 400, object: ["error": ["message": "secret-key-value"]])
        XCTAssertFalse(error.localizedDescription.contains("secret-key-value"))
    }

    func testRepairFeedbackExplainsConcreteFailureAndChangesSecondAttempt() throws {
        let payload = ["summary": "Create a PDF", "command": "python3 <<'PY'\nprint('pdf')\nPY"]
        let text = "<SORA_COMMAND>" + String(decoding: try JSONEncoder().encode(payload), as: UTF8.self) + "</SORA_COMMAND>"
        XCTAssertTrue(AgentEnvelope.needsRepair(text))
        XCTAssertTrue(AgentEnvelope.repairFeedback(for: text, attempt: 1).contains("newline or tab"))
        XCTAssertTrue(AgentEnvelope.repairFeedback(for: text, attempt: 2).contains("Change approach"))
        XCTAssertTrue(AgentEnvelope.repairFeedback(for: "<SORA_COMMAND>{", attempt: 1).contains("Missing closing tag"))
        XCTAssertTrue(AgentEnvelope.repairFeedback(for: text + text, attempt: 1).contains("Multiple actions"))
    }

    func testRejectedActionDiagnosticsRemainSeparateFromRepairInstructions() {
        let reasons = AgentEnvelope.validationReasons(for: "<SORA_COMMAND>{")
        XCTAssertEqual(reasons, ["Missing closing tag: </SORA_COMMAND>"])
        XCTAssertFalse(reasons.joined().contains("Answer the original"))
        XCTAssertTrue(AgentEnvelope.explanationFallback.contains("No action was executed"))
        XCTAssertTrue(AgentEnvelope.explanationFallback.contains("Do not emit any SORA"))
    }

    func testMixedActionEnvelopesRequireRepair() {
        let command = #"<SORA_COMMAND>{"summary":"List files.","command":"ls"}</SORA_COMMAND>"#
        let webpage = #"<SORA_WEBPAGE>{"summary":"Read docs.","url":"https://example.com"}</SORA_WEBPAGE>"#
        XCTAssertFalse(AgentEnvelope.needsRepair(command))
        XCTAssertFalse(AgentEnvelope.needsRepair(webpage))
        XCTAssertFalse(AgentEnvelope.needsRepair("An ordinary answer."))
        XCTAssertTrue(AgentEnvelope.needsRepair(command + webpage))
        XCTAssertTrue(AgentEnvelope.needsRepair(command + command))
        XCTAssertTrue(AgentEnvelope.needsRepair("<SORA_COMMAND>"))
        XCTAssertNil(AgentCommandProposalParser.match(command + webpage))
        XCTAssertNil(AgentWebpageProposalParser.match(command + webpage))
    }

    func testRealtimeCaptureRecoversFromFaultedVoiceProcessing() {
        var health = RealtimeCaptureHealth()
        XCTAssertEqual(health.action(usesVoiceProcessing: true), .retryWithoutVoiceProcessing)
        XCTAssertEqual(health.action(usesVoiceProcessing: false), .captureFailed)
        health.record(hasSignal: false)
        XCTAssertEqual(health.action(usesVoiceProcessing: true), .retryWithoutVoiceProcessing)
        // A working raw microphone can legitimately deliver silence.
        XCTAssertEqual(health.action(usesVoiceProcessing: false), .healthy)
        health.record(hasSignal: true)
        health.record(hasSignal: false)
        XCTAssertEqual(health.action(usesVoiceProcessing: true), .healthy)
    }

    func testRealtimeVoiceModelCapabilityUsesExplicitCurrentModelsAndSnapshots() {
        XCTAssertTrue(RealtimeVoiceModel.isSupported("gpt-realtime-2.1"))
        XCTAssertTrue(RealtimeVoiceModel.isSupported("gpt-realtime-2.1-2026-08-01"))
        XCTAssertTrue(RealtimeVoiceModel.isSupported(" gpt-realtime-1.5 "))
        XCTAssertFalse(RealtimeVoiceModel.isSupported("gpt-5.4-mini"))
        XCTAssertFalse(RealtimeVoiceModel.isSupported("gpt-realtime"))
        XCTAssertFalse(RealtimeVoiceModel.isSupported(""))
    }

    func testRealtimeVoiceClientEventsUseTextWebSocketFrames() throws {
        let message = try RealtimeVoiceWireCodec.outboundMessage(for: [
            "type": "input_audio_buffer.append",
            "audio": "AQID"
        ])

        guard case .string(let text) = message else {
            return XCTFail("Realtime client events must be sent as text frames.")
        }
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        )
        XCTAssertEqual(value["type"], "input_audio_buffer.append")
        XCTAssertEqual(value["audio"], "AQID")
    }

    func testRealtimeVoiceTruncationNeverExceedsReceivedAudio() {
        let receivedBytesFor7Point3Seconds = 24_000 * 2 * 7_300 / 1_000

        XCTAssertEqual(
            RealtimeVoiceTiming.truncationMilliseconds(
                playedMilliseconds: 8_458,
                receivedPCMByteCount: receivedBytesFor7Point3Seconds
            ),
            7_299
        )
        XCTAssertEqual(
            RealtimeVoiceTiming.truncationMilliseconds(
                playedMilliseconds: 1_500,
                receivedPCMByteCount: receivedBytesFor7Point3Seconds
            ),
            1_500
        )
        // An interruption before the player starts must discard all queued audio.
        XCTAssertEqual(
            RealtimeVoiceTiming.truncationMilliseconds(
                playedMilliseconds: 0,
                receivedPCMByteCount: receivedBytesFor7Point3Seconds
            ),
            0
        )
        XCTAssertNil(
            RealtimeVoiceTiming.truncationMilliseconds(
                playedMilliseconds: 100,
                receivedPCMByteCount: 0
            )
        )

        XCTAssertTrue(
            RealtimeVoiceTiming.shouldInterruptPlayback(isSpeaking: true, scheduledAudioBuffers: 0)
        )
        XCTAssertTrue(
            RealtimeVoiceTiming.shouldInterruptPlayback(isSpeaking: false, scheduledAudioBuffers: 1)
        )
        XCTAssertFalse(
            RealtimeVoiceTiming.shouldInterruptPlayback(isSpeaking: false, scheduledAudioBuffers: 0)
        )
    }

    func testCommandProposalEnvelopeIsStrictAndSingleLine() throws {
        let valid = #"<SORA_COMMAND>{"summary":"List the largest files without changing them.","command":"find . -type f -print | head"}</SORA_COMMAND>"#
        XCTAssertEqual(
            AgentCommandProposalParser.match(valid)?.proposal,
            AgentCommandProposal(
                summary: "List the largest files without changing them.",
                command: "find . -type f -print | head"
            )
        )
        XCTAssertNil(AgentCommandProposalParser.match(#"<SORA_COMMAND>{"summary":"Run it","command":"pwd\nwhoami"}</SORA_COMMAND>"#))
        XCTAssertNil(AgentCommandProposalParser.match(#"<SORA_COMMAND>{"summary":"","command":"pwd"}</SORA_COMMAND>"#))
        XCTAssertFalse(AgentCommandProposal.isValidCommand("pwd\u{1B}"))
        XCTAssertFalse(AgentCommandProposal.isValidCommand("echo safe\u{202E}txt"))
    }

    func testEnvelopeIsFoundWhenTheModelWrapsItInProse() throws {
        let valid = #"<SORA_COMMAND>{"summary":"List the largest files.","command":"find . -type f -print | head"}</SORA_COMMAND>"#
        let match = try XCTUnwrap(AgentCommandProposalParser.match("Run this:\n\(valid)\nThen review it."))
        XCTAssertEqual(match.proposal.command, "find . -type f -print | head")
        XCTAssertEqual(match.prose, "Run this:\n\nThen review it.")

        // Two envelopes leave the intent ambiguous.
        XCTAssertNil(AgentCommandProposalParser.match("\(valid)\n\(valid)"))
    }

    func testEnvelopeWithUnescapedQuotesIsRecoveredRatherThanShownRaw() throws {
        // Verbatim shape from a Homebrew install proposal: the inner quotes in
        // `command` are unescaped, so strict JSON decoding fails.
        let text = #"<SORA_COMMAND>{"summary":"Install Homebrew so yt-dlp can be installed afterward","command":"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""} </SORA_COMMAND>"#
        let match = try XCTUnwrap(AgentCommandProposalParser.match(text))
        XCTAssertEqual(match.proposal.summary, "Install Homebrew so yt-dlp can be installed afterward")
        XCTAssertEqual(
            match.proposal.command,
            #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        )
        XCTAssertTrue(match.prose.isEmpty)
    }

    func testRecoveryStillRejectsMultiLineCommands() {
        let text = #"<SORA_COMMAND>{"summary":"Two steps","command":"pwd\nwhoami "and" more"}</SORA_COMMAND>"#
        XCTAssertNil(AgentCommandProposalParser.match(text))
    }

    func testProseBeforeEnvelopeHidesCompleteAndPartialTags() {
        XCTAssertNil(AgentCommandProposalParser.proseBeforeEnvelope(in: "Just an answer."))
        XCTAssertEqual(
            AgentCommandProposalParser.proseBeforeEnvelope(in: "Here we go. <SORA_COMMAND>{\"summ"),
            "Here we go."
        )
        // Mid-stream the tag itself arrives in pieces.
        XCTAssertEqual(
            AgentCommandProposalParser.proseBeforeEnvelope(in: "Here we go. <SORA_"),
            "Here we go."
        )
    }

    func testWebpageProposalEnvelopeRequiresPublicHTTPS() {
        let valid = #"<SORA_WEBPAGE>{"summary":"Read the docs landing page","url":"https://example.com/docs"}</SORA_WEBPAGE>"#
        XCTAssertEqual(
            AgentWebpageProposalParser.match(valid)?.proposal,
            AgentWebpageProposal(summary: "Read the docs landing page", url: "https://example.com/docs")
        )
        XCTAssertEqual(AgentWebpageProposalParser.proseBeforeEnvelope(in: "<SORA_WEBPAGE>"), "")
        XCTAssertNil(AgentWebpageProposalParser.match(#"<SORA_WEBPAGE>{"summary":"Local","url":"http://example.com"}</SORA_WEBPAGE>"#))
        XCTAssertNil(AgentWebpageProposalParser.match(#"<SORA_WEBPAGE>{"summary":"Local","url":"https://localhost/docs"}</SORA_WEBPAGE>"#))
        XCTAssertNil(AgentWebpageProposalParser.match(#"<SORA_WEBPAGE>{"summary":"","url":"https://example.com"}</SORA_WEBPAGE>"#))
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
            } catch { if mode.hasSuffix("eof") {
                    XCTAssertTrue(error is AIError)
                } else {
                    XCTAssertTrue(error is ProviderAPIError)
                    let expected = mode.hasSuffix("401") ? "Authentication" : mode.hasSuffix("length") ? "output-token limit" : mode.hasSuffix("quota") ? "credits or spending limit" : "temporarily limited"
                    XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                } }
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
        for mode in ["fixture-401", "fixture-429", "fixture-quota", "fixture-eof"] {
            do {
                for try await _ in provider.events(for: request, credential: mode) {}
                XCTFail("Expected a visible failure for \(mode)")
            } catch {
                if mode.hasSuffix("eof") {
                    XCTAssertTrue(error is AIError)
                } else {
                    XCTAssertTrue(error is ProviderAPIError)
                    let expected = mode.hasSuffix("401") ? "Authentication" : mode.hasSuffix("length") ? "output-token limit" : mode.hasSuffix("quota") ? "credits or spending limit" : "temporarily limited"
                    XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                }
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
        let status = mode.hasSuffix("401") ? 401 : (mode.hasSuffix("429") || mode.hasSuffix("quota")) ? 429 : 200
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
        if mode.hasSuffix("quota") {
            body = #"{"error":{"type":"insufficient_quota","message":"You exceeded your current quota"}}"#
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
        AskSession(provider: provider, credentials: key, conversations: store, defaults: defaults, programStore: AgentProgramStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
    }

    func testWindowSessionsStreamAndStopIndependently() async {
        let aProvider = ControlledProvider(), bProvider = ControlledProvider()
        let a = makeSession(aProvider), b = makeSession(bProvider)
        a.enabled = true
        b.enabled = true
        a.bindTab(UUID()); b.bindTab(UUID())
        a.draft = "Window A"; b.draft = "Window B"
        a.send(); b.send()
        await waitFor { aProvider.requests.count == 1 && bProvider.requests.count == 1 }
        aProvider.emit(.text("A reply")); bProvider.emit(.text("B reply"))
        await waitFor { b.messages.last?.text == "B reply" }
        a.stop()
        a.bindTab(UUID())
        XCTAssertTrue(b.isSending)
        XCTAssertEqual(b.messages.first?.text, "Window B")
        bProvider.emit(.text(" continues")); bProvider.emit(.completed); bProvider.finish()
        await waitFor { !b.isSending }
        XCTAssertEqual(b.messages.last?.text, "B reply continues")
        XCTAssertTrue(a.messages.isEmpty)
        b.draft = "Private draft"
        XCTAssertTrue(a.draft.isEmpty)
        XCTAssertEqual(b.draft, "Private draft")
    }

    func testSharedPreferencesReachOtherWindowsWithoutSharingDrafts() async {
        let a = makeSession(), b = makeSession()
        b.draft = "Keep this draft"
        a.enabled = true
        a.model = "custom-model"
        a.permissionMode = .fullAccess
        await waitFor { b.enabled && b.model == "custom-model" && b.permissionMode == .fullAccess }
        XCTAssertEqual(b.draft, "Keep this draft")
        a.enabled = false
        await waitFor { !b.enabled }
    }

    func testProgramChangesRefreshWindowsAndStaleRemovalPreservesNewEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProgramStore(directory: root)
        let a = makeSession(), b = makeSession()
        a.reloadPrograms(store: store); b.reloadPrograms(store: store)
        let first = AgentProgram(name: "First", summary: "Print", script: "echo one", directory: "/tmp")
        let second = AgentProgram(name: "Second", summary: "Print", script: "echo two", directory: "/tmp")
        try store.save([first])
        await waitFor { a.programs.count == 1 && b.programs.count == 1 }
        try store.save([first, second])
        // Act before asynchronous catalog notifications have refreshed A.
        a.removeProgram(first.id)
        XCTAssertEqual(try store.load(), [second])
        await waitFor { b.programs == [second] }
    }

    func testLiveWindowConversationStoresHaveSeparatePaths() throws {
        let a = AIBackend.live(windowID: UUID()), b = AIBackend.live(windowID: UUID())
        for (left, right) in zip(a, b) {
            let l = try XCTUnwrap(left.conversations as? FileAIConversationStore)
            let r = try XCTUnwrap(right.conversations as? FileAIConversationStore)
            XCTAssertNotEqual(l.url, r.url)
            XCTAssertTrue(l.url.path.contains("/AgentWindows/"))
        }
    }

    func testProgramsSaveAfterReviewPersistAndRunWithoutProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sora-program-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProgramStore(directory: root)
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.reloadPrograms(store: store)
        session.enabled = true
        session.permissionMode = .fullAccess
        session.configureAgent(directory: FileManager.default.temporaryDirectory)
        session.draft = "Save the workflow"
        session.send()
        await waitFor { provider.requests.count == 1 }
        let payload = ["action": "save", "name": "Report", "summary": "Print a local report", "script": "set -e\nprintf 'reused-program\\n'\n"]
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        provider.emit(.text("<SORA_PROGRAM>" + json + "</SORA_PROGRAM>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertTrue(session.programs.isEmpty, "Even Full access must not automatically save or run a program")
        let message = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(message.programProposal?.status, .pending)
        session.saveProgram(messageID: message.id)
        let program = try XCTUnwrap(session.programs.first)
        XCTAssertEqual(try store.load(), [program])
        session.saveProgram(messageID: message.id)
        XCTAssertEqual(session.programs.count, 1)

        let reopened = makeSession(provider)
        reopened.reloadPrograms(store: store)
        XCTAssertEqual(reopened.programs, [program])
        reopened.enabled = false
        reopened.runProgram(program.id)
        await waitFor { !reopened.isRunningCommand }
        XCTAssertEqual(reopened.messages.last?.commandResult?.exitCode, 0)
        XCTAssertTrue(reopened.messages.last?.commandResult?.output.contains("reused-program") == true)
        XCTAssertEqual(provider.requests.count, 1, "Replay must not call the provider, including after execution")
        reopened.removeProgram(program.id)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testProgramCatalogIsCompactAndUnknownProgramDoesNotRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProgramStore(directory: root)
        let program = AgentProgram(name: "Report", summary: "List files", script: "print UNIQUE_SCRIPT_BODY", directory: "/tmp")
        try store.save([program])
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.reloadPrograms(store: store)
        session.enabled = true
        session.draft = "Run @report with this input"
        session.send()
        await waitFor { provider.requests.count == 1 }
        let text = try XCTUnwrap(provider.requests.last?.messages.last?.text)
        XCTAssertTrue(text.contains(program.id.uuidString))
        XCTAssertFalse(text.contains("UNIQUE_SCRIPT_BODY"))
        XCTAssertTrue(text.contains("Explicit program mentions resolved by Sora"))
        provider.emit(.text("<SORA_PROGRAM>{\"action\":\"run\",\"id\":\"" + UUID().uuidString + "\"}</SORA_PROGRAM>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertNil(session.messages.last?.programProposal)
        XCTAssertFalse(session.isRunningCommand)
        XCTAssertTrue(session.messages.last?.text.contains("no longer") == true)
    }

    func testRealtimeVoiceAvailabilityAndTranscriptLifecycle() {
        let store = MemoryConversation()
        let session = makeSession(store: store)
        XCTAssertFalse(session.realtimeVoiceAvailability.isAvailable)
        session.enabled = true
        XCTAssertTrue(session.realtimeVoiceAvailability.isAvailable)
        session.realtimeVoiceModel = "gpt-5.4-mini"
        XCTAssertFalse(session.realtimeVoiceAvailability.isAvailable)
        session.realtimeVoiceModel = RealtimeVoiceModel.recommended

        let id = session.beginRealtimeVoiceMessage(role: .user)
        session.updateRealtimeVoiceMessage(id: id, text: "Hello", completed: false)
        XCTAssertEqual(session.messages.last?.status, .streaming)
        XCTAssertEqual(session.messages.last?.isVoiceInput, true)
        session.updateRealtimeVoiceMessage(id: id, text: "Hello Sora", completed: true)
        XCTAssertEqual(session.messages.last?.status, .complete)
        XCTAssertEqual(store.messages.last?.text, "Hello Sora")
    }

    func testAgentRunsCommandAndFeedsOutputBackBeforeSummarizing() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.permissionMode = .approveForMe
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

    func testAskForApprovalLeavesSafeCommandsPending() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.permissionMode = .askForApproval
        session.configureAgent(directory: URL(fileURLWithPath: "/private/tmp"))
        session.draft = "Show me the current directory"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("<SORA_COMMAND>{\"summary\":\"Read directory\",\"command\":\"pwd\"}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.last?.commandProposal?.status, .pending)
        XCTAssertNil(session.messages.last?.commandResult)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testFullAccessAutoRunsCommandsThatNeedApprovalUnderSaferModes() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.permissionMode = .fullAccess
        session.configureAgent(directory: URL(fileURLWithPath: "/private/tmp"))
        session.draft = "Print hello"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("<SORA_COMMAND>{\"summary\":\"Say hello\",\"command\":\"printf hello\"}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { provider.requests.count == 2 }
        XCTAssertEqual(session.messages.compactMap(\.commandResult).first?.output, "hello")
        XCTAssertFalse(AgentCommandPermission.allowsAutomatically("printf hello"))
        XCTAssertTrue(AgentCommandPermission.shouldAutoRunCommand("printf hello", mode: .fullAccess))
    }

    func testAgentFeedsFailureBackAndStopsAtCommandLimit() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.permissionMode = .approveForMe
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
        XCTAssertTrue(session.errorMessage?.contains("six agent actions") == true)
        XCTAssertFalse(session.isRunningCommand)
    }

    func testAutomaticCommandPolicyRejectsShellEscapesAndMutations() {
        for command in ["pwd", "ls -lah", "du -sh .", "find . -type f -print0 | xargs -0 du -h | sort -hr | head -20"] {
            XCTAssertTrue(AgentCommandPermission.allowsAutomatically(command), command)
            XCTAssertTrue(AgentCommandPermission.shouldAutoRunCommand(command, mode: .approveForMe), command)
            XCTAssertFalse(AgentCommandPermission.shouldAutoRunCommand(command, mode: .askForApproval), command)
        }
        for command in ["rm file", "find . -delete", "find . -exec rm {} +", "ls; rm file", "ls $(touch file)", "ls > file", "xargs sh", "ls | xargs sh", "ls\npwd", "curl example.com", "ls --help"] {
            XCTAssertFalse(AgentCommandPermission.allowsAutomatically(command), command)
            XCTAssertFalse(AgentCommandPermission.shouldAutoRunCommand(command, mode: .approveForMe), command)
            XCTAssertTrue(AgentCommandPermission.shouldAutoRunCommand(command, mode: .fullAccess) == AgentCommandProposal.isValidCommand(command), command)
        }
        XCTAssertFalse(AgentCommandPermission.shouldAutoFetchWebpage(mode: .askForApproval))
        XCTAssertFalse(AgentCommandPermission.shouldAutoFetchWebpage(mode: .approveForMe))
        XCTAssertTrue(AgentCommandPermission.shouldAutoFetchWebpage(mode: .fullAccess))
        XCTAssertEqual(AgentPermissionMode.stored(in: UserDefaults(suiteName: "sora-perm-\(UUID())")!), .askForApproval)
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

    func testRunnerSeesToolsOnTheLoginShellSearchPath() async throws {
        // Regression: a hardcoded /usr/bin PATH hid Homebrew, so the agent
        // reported installed tools as missing and offered to reinstall them.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sora-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("sora-fixture-tool")
        try "#!/bin/sh\necho fixture\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let runner = AgentCommandRunner(searchPath: "\(directory.path):/usr/bin:/bin")
        let found = try await runner.run(command: "sora-fixture-tool", directory: directory)
        XCTAssertEqual(found.exitCode, 0)
        XCTAssertEqual(found.output.trimmingCharacters(in: .whitespacesAndNewlines), "fixture")

        let hidden = try await AgentCommandRunner(searchPath: "/usr/bin:/bin")
            .run(command: "sora-fixture-tool", directory: directory)
        XCTAssertNotEqual(hidden.exitCode, 0)
    }

    func testLoginShellPathParsingAndResolution() {
        XCTAssertEqual(
            LoginShellPath.parse("noise\(LoginShellPath.beginMarker)/opt/homebrew/bin:/usr/bin\(LoginShellPath.endMarker)"),
            "/opt/homebrew/bin:/usr/bin"
        )
        XCTAssertNil(LoginShellPath.parse("no markers here"))
        XCTAssertNil(LoginShellPath.parse("\(LoginShellPath.beginMarker)\(LoginShellPath.endMarker)"))
        // A path spanning lines is malformed.
        XCTAssertNil(LoginShellPath.parse("\(LoginShellPath.beginMarker)/usr/bin\n/bin\(LoginShellPath.endMarker)"))
        // The real shell on this machine must at least return the system path.
        let resolved = try? XCTUnwrap(LoginShellPath.resolve())
        XCTAssertTrue(resolved?.contains("/usr/bin") == true, "resolved path: \(resolved ?? "nil")")
        XCTAssertTrue(LoginShellPath.value.contains("/usr/bin"))
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

    func testAgentResumeSummaryUsesTitleAndLatestFollowUp() async {
        XCTAssertEqual(AgentResumeSummary.title(from: "Help me find the largest files"), "Find the largest files")
        XCTAssertEqual(AgentResumeSummary.title(from: "can you explain pwd"), "Explain pwd")

        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.bindTab(UUID())
        session.beginTerminalAgent(question: "Help me find the largest files", directory: URL(fileURLWithPath: "/private/tmp"))
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("First answer"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.resumeSummary?.title, "Find the largest files")
        XCTAssertNil(session.resumeSummary?.latestFollowUp)

        session.draft = "How about in ~/Downloads?"
        session.send()
        await waitFor { provider.requests.count == 2 }
        provider.emit(.text("Downloads answer"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.resumeSummary?.title, "Find the largest files")
        XCTAssertEqual(session.resumeSummary?.latestFollowUp, "How about in ~/Downloads?")
    }

    func testAgentFetchesWebpageAndFeedsSnapshotBack() async {
        let provider = ControlledProvider()
        let page = WebpageAttachment(
            url: URL(string: "https://example.com/docs")!,
            title: "Docs",
            text: "Installation steps for Sora.",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isExcerpt: false
        )
        let session = AskSession(
            provider: provider,
            credentials: MemoryKey(),
            conversations: MemoryConversation(),
            defaults: defaults, programStore: AgentProgramStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)),
            webpageFetcher: FixedWebpageFetcher(page: page)
        )
        session.enabled = true
        session.permissionMode = .fullAccess
        session.bindTab(UUID())
        session.beginTerminalAgent(question: "Summarize https://example.com/docs", directory: URL(fileURLWithPath: "/private/tmp"))
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text(#"<SORA_WEBPAGE>{"summary":"Read the docs page","url":"https://example.com/docs"}</SORA_WEBPAGE>"#))
        provider.emit(.completed)
        provider.finish()
        await waitFor { provider.requests.count == 2 }
        XCTAssertEqual(session.messages.compactMap(\.webpage).first?.title, "Docs")
        XCTAssertTrue((try? provider.requests.last?.messages.map { try $0.contentForProvider() }.joined().contains("Webpage snapshot")) == true)
        provider.emit(.text("The docs cover installation steps."))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertTrue(session.messages.last?.text.contains("installation") == true)
    }

    func testStopWhileWaitingForKeychainPreventsLateNetworkRequest() async {
        let key = DelayedKey()
        let provider = ControlledProvider()
        let session = AskSession(provider: provider, credentials: key,
                                 conversations: MemoryConversation(), defaults: defaults, programStore: AgentProgramStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
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
        let session = AskSession(backends: backends, defaults: defaults, programStore: AgentProgramStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
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
            credentials: MemoryKey(nil), conversations: MemoryConversation())], defaults: defaults, programStore: AgentProgramStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
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

    func testMalformedActionAutomaticallyRepairsWithoutDuplicatingTurn() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.draft = "Create a folder"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("<SORA_COMMAND>{broken}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { provider.requests.count == 2 }
        XCTAssertTrue(session.isSending)
        XCTAssertNil(session.messages.last?.commandProposal)
        XCTAssertTrue(provider.requests.last?.messages.last?.text.contains("Validation feedback:") == true)
        XCTAssertEqual(provider.requests.last?.messages.dropLast().last?.text, "<SORA_COMMAND>{broken}</SORA_COMMAND>")
        provider.emit(.text(#"<SORA_COMMAND>{"summary":"Create the folder.","command":"mkdir example"}</SORA_COMMAND>"#))
        provider.emit(.completed)
        provider.finish()
        await waitFor { !session.isSending }
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages.last?.commandProposal?.status, .pending)
        XCTAssertEqual(session.messages.last?.commandProposal?.command, "mkdir example")
        XCTAssertNil(session.errorMessage)
    }

    func testMalformedActionRetriesAreBoundedAndFailedTurnExcluded() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.draft = "Find a page"
        session.send()
        for count in 1...4 {
            await waitFor { provider.requests.count == count }
            if count == 3 {
                XCTAssertTrue(provider.requests.last?.messages.last?.text.contains("Change approach") == true)
                XCTAssertEqual(provider.requests.last?.messages.dropLast().last?.text, "<SORA_WEBPAGE>{broken}</SORA_WEBPAGE>")
            }
            if count == 4 { XCTAssertTrue(provider.requests.last?.messages.last?.text.contains("Do not emit any SORA") == true) }
            provider.emit(.text("<SORA_WEBPAGE>{broken}</SORA_WEBPAGE>"))
            provider.emit(.completed)
            provider.finish()
        }
        await waitFor { !session.isSending }
        XCTAssertEqual(provider.requests.count, 4)
        XCTAssertEqual(session.messages.last?.status, .failed)
        XCTAssertNil(session.messages.last?.webpageProposal)
        XCTAssertFalse(session.messages.last?.text.contains("SORA_") ?? true)
        XCTAssertTrue(session.errorMessage?.contains("two repair attempts") == true)
        session.draft = "Explain pwd"
        session.send()
        await waitFor { provider.requests.count == 5 }
        XCTAssertEqual(provider.requests.last?.messages.map(\.text), ["Explain pwd"])
        session.stop()
    }

    func testStopDuringRepairRejectsLateProposal() async {
        let provider = ControlledProvider()
        let session = makeSession(provider)
        session.enabled = true
        session.draft = "Create a folder"
        session.send()
        await waitFor { provider.requests.count == 1 }
        provider.emit(.text("<SORA_COMMAND>{broken}</SORA_COMMAND>"))
        provider.emit(.completed)
        provider.finish()
        await waitFor { provider.requests.count == 2 }
        session.stop()
        provider.emit(.text(#"<SORA_COMMAND>{"summary":"Create folder.","command":"mkdir example"}</SORA_COMMAND>"#))
        provider.emit(.completed)
        provider.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.messages.last?.status, .stopped)
        XCTAssertNil(session.messages.last?.commandProposal)
        XCTAssertEqual(provider.requests.count, 2)
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

private struct FixedWebpageFetcher: WebpageFetching {
    let page: WebpageAttachment
    func fetch(_ address: String) async throws -> WebpageAttachment { page }
}


final class AgentProgramTests: XCTestCase {
    func testProgramBackupRecoversCorruptionWithoutLosingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProgramStore(directory: root)
        let program = AgentProgram(name: "Saved", summary: "Report", script: "pwd", directory: "/missing-working-folder")
        try store.save([program])
        XCTAssertEqual(try store.load(), [program])
        XCTAssertThrowsError(try store.command(for: program))
        XCTAssertEqual(try store.load(), [program], "A missing working folder must never remove a program")
        let catalog = root.appendingPathComponent("catalog.json")
        try Data("damaged".utf8).write(to: catalog)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]), "Do not replace damaged catalog or backup")
        XCTAssertEqual(try store.restoreBackup(), [program])
        XCTAssertEqual(try store.load(), [program])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("catalog-before-restore-") })
        try FileManager.default.removeItem(at: catalog)
        XCTAssertThrowsError(try store.load(), "Missing catalog must not silently appear empty when a backup exists")
        XCTAssertEqual(try store.restoreBackup(), [program])
    }

    func testProgramMentionCompletionAndResolution() {
        let program = AgentProgram(name: "YouTube captions", summary: "Captions", script: "print ok", directory: "/tmp")
        XCTAssertEqual(ProgramMention.query(in: "Run @you"), "you")
        XCTAssertEqual(ProgramMention.query(in: "@"), "")
        XCTAssertNil(ProgramMention.query(in: "hello@example.com"))
        XCTAssertNil(ProgramMention.query(in: "@youtube-captions "))
        XCTAssertNil(ProgramMention.query(in: ""))
        let inserted = ProgramMention.inserting(program, into: "Run @you", programs: [program])
        XCTAssertEqual(inserted, "Run @youtube-captions ")
        XCTAssertEqual(ProgramMention.resolve(inserted + "https://example.com", programs: [program]), [program])
        XCTAssertTrue(ProgramMention.resolve("@youtube", programs: [program]).isEmpty)
        let duplicate = AgentProgram(name: program.name, summary: "Other", script: "pwd", directory: "/tmp")
        let programs = [program, duplicate]
        XCTAssertNotEqual(ProgramMention.handle(program, in: programs), ProgramMention.handle(duplicate, in: programs))
        XCTAssertEqual(ProgramMention.resolve("@" + ProgramMention.handle(duplicate, in: programs), programs: programs), [duplicate])
    }

    func testProgramArgumentsArriveLiterallyWithoutShellEvaluation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProgramStore(directory: root)
        let program = AgentProgram(name: "Arguments", summary: "Print inputs", script: "printf '%s\\n' \"$#\" \"$@\"", directory: "/tmp")
        let arguments = ["https://www.youtube.com/watch?v=3bL6IpdgddQ&list=example", "a path with spaces", "it's literal", "$(printf INJECTED); `pwd`"]
        let command = try store.command(for: program, arguments: arguments)
        let result = try await AgentCommandRunner().run(command: command, directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, (["4"] + arguments).joined(separator: "\n") + "\n")
    }

    func testProgramRunEnvelopeRetainsURLAndLegacyProposalStillDecodes() throws {
        let id = UUID().uuidString
        let text = "<SORA_PROGRAM>{\"action\":\"run\",\"id\":\"" + id + "\",\"arguments\":[\"https://www.youtube.com/watch?v=abc&list=def\"]}</SORA_PROGRAM>"
        XCTAssertEqual(AgentProgramProposal.match(text)?.proposal.arguments, ["https://www.youtube.com/watch?v=abc&list=def"])
        XCTAssertFalse(AgentEnvelope.needsRepair(text))
        let old = Data(("{\"action\":\"run\",\"id\":\"" + id + "\",\"status\":\"pending\"}").utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentProgramProposal.self, from: old).arguments)
        XCTAssertEqual(ProgramArguments.lines("one URL\na path with spaces"), ["one URL", "a path with spaces"])
        XCTAssertFalse(ProgramArguments.isValid(["bad\0argument"]))
        XCTAssertFalse(ProgramArguments.isValid(Array(repeating: "a", count: 33)))
    }

    func testStrictProgramEnvelopesAndMixedActions() throws {
        let payload = ["action": "save", "name": "Report", "summary": "Print report", "script": "set -e\nprintf 'hello\\n'\n"]
        let text = "<SORA_PROGRAM>" + String(decoding: try JSONEncoder().encode(payload), as: UTF8.self) + "</SORA_PROGRAM>"
        XCTAssertEqual(AgentProgramProposal.match(text)?.proposal.script, payload["script"])
        XCTAssertFalse(AgentEnvelope.needsRepair(text))
        XCTAssertTrue(AgentEnvelope.needsRepair(text + text))
        XCTAssertTrue(AgentEnvelope.needsRepair("<SORA_PROGRAM>{\"action\":\"run\",\"id\":\"../../bad\"}</SORA_PROGRAM>"))
        XCTAssertFalse(AgentProgram.valid(name: "bad\nname", summary: "summary", script: "ls"))
        XCTAssertFalse(AgentProgram.valid(name: "name", summary: "summary", script: String(repeating: "x", count: 24_001)))
        XCTAssertFalse(AgentProgram.valid(name: "name", summary: "summary", script: "ls\0"))
    }

    func testCorruptCatalogIsNotOverwrittenByLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("catalog.json")
        let data = Data("not json".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try AgentProgramStore(directory: root).load())
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testScriptPathQuotesAndRegeneratesFromSavedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sora's programs " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProgramStore(directory: root)
        let program = AgentProgram(name: "Report", summary: "Print", script: "print hello", directory: "/tmp")
        let command = try store.command(for: program)
        XCTAssertTrue(command.contains("'\\''"))
        let file = root.appendingPathComponent(program.id.uuidString + ".sh")
        try Data("print changed".utf8).write(to: file)
        _ = try store.command(for: program)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), program.script)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
}

final class ConversationDebugLogTests: XCTestCase {
    func testExportIncludesConversationMetadataAndRejectedAction() throws {
        var message = AIMessage(role: .assistant, text: "Could not install")
        let rejected = "<SORA_COMMAND>{\"summary\":\"Install\",\"command\":\"echo first\\necho second\"}</SORA_COMMAND>"
        message.recordRejectedAction(rejected, attempt: 1)
        let log = try ConversationDebugLog.render(
            messages: [AIMessage(role: .user, text: "Install this program"), message],
            provider: "openai", model: "test-model", permissionMode: "ask", error: "Invalid action")
        let json = String(log[log.range(of: "{\n")!.lowerBound...])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(object["model"] as? String, "test-model")
        XCTAssertEqual(object["error"] as? String, "Invalid action")
        let messages = object["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 2)
        let diagnostics = messages[1]["actionDiagnostics"] as! [[String: Any]]
        XCTAssertEqual(diagnostics[0]["responseExcerpt"] as? String, rejected)
        XCTAssertFalse((diagnostics[0]["reasons"] as! [String]).isEmpty)
        XCTAssertFalse(try message.contentForProvider().contains("SORA_COMMAND"))
    }

    func testRejectedActionCaptureIsBoundedAndSurvivesCoding() throws {
        var message = AIMessage(role: .assistant, text: "Failed")
        message.recordRejectedAction(String(repeating: "x", count: 20_000), attempt: 2)
        let restored = try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.actionDiagnostics?.first?.responseExcerpt.utf8.count, 12_000)
        XCTAssertEqual(restored.actionDiagnostics?.first?.truncated, true)
        var legacy = message
        legacy.actionDiagnostics = nil
        XCTAssertNil(try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(legacy)).actionDiagnostics)
    }
}
