import Foundation

enum AIBackendID: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai, codex, anthropic, gateway, grok
    var id: String { rawValue }
    var name: String {
        switch self {
        case .openai: return "OpenAI API"
        case .codex: return "Codex"
        case .anthropic: return "Anthropic API"
        case .gateway: return "Vercel AI Gateway"
        case .grok: return "Grok (xAI)"
        }
    }
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5.4-mini"
        case .codex: return "" // Codex chooses from its account's model catalog.
        case .anthropic: return "claude-sonnet-4-6"
        case .gateway: return "openai/gpt-5.4"
        case .grok: return "grok-4.6"
        }
    }
    var needsKey: Bool { self != .codex }
    var disclosure: String {
        switch self {
        case .openai: return "This OpenAI conversation is sent to OpenAI."
        case .codex: return "This Codex conversation uses your Codex sign-in."
        case .anthropic: return "This Anthropic conversation is sent to Anthropic."
        case .gateway: return "This Gateway conversation is sent through Vercel to the selected model provider."
        case .grok: return "This Grok conversation is sent to xAI."
        }
    }
}

enum RealtimeVoiceModel {
    static let recommended = "gpt-realtime-2.1"
    static let supported = [
        "gpt-realtime-2.1",
        "gpt-realtime-2.1-mini",
        "gpt-realtime-2",
        "gpt-realtime-1.5"
    ]

    static func isSupported(_ model: String) -> Bool {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return supported.contains(value)
            || supported.contains(where: { value.hasPrefix($0 + "-") })
    }
}

enum RealtimeVoiceWireCodec {
    static func outboundMessage(for event: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeVoiceError.connectionFailed
        }
        return .string(text)
    }
}

enum RealtimeVoiceTiming {
    static let pcmSampleRate = 24_000
    static let pcmBytesPerFrame = MemoryLayout<Int16>.size

    static func truncationMilliseconds(
        playedMilliseconds: Int,
        receivedPCMByteCount: Int
    ) -> Int? {
        guard playedMilliseconds >= 0, receivedPCMByteCount >= pcmBytesPerFrame else { return nil }
        let receivedFrames = receivedPCMByteCount / pcmBytesPerFrame
        let receivedMilliseconds = receivedFrames * 1_000 / pcmSampleRate
        guard receivedMilliseconds > 0 else { return nil }

        // Stay just inside the received audio boundary. Realtime rejects a
        // truncate timestamp that is even slightly beyond the item's audio.
        let safeReceivedMilliseconds = receivedMilliseconds - 1
        return min(playedMilliseconds, safeReceivedMilliseconds)
    }

    static func shouldInterruptPlayback(isSpeaking: Bool, scheduledAudioBuffers: Int) -> Bool {
        isSpeaking || scheduledAudioBuffers > 0
    }
}

enum RealtimeVoiceAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

struct AIBackend {
    let id: AIBackendID
    let provider: any AIProvider
    let credentials: any AICredentialStore
    let conversations: any AIConversationStore

    static func live(windowID: UUID? = nil, tabID: UUID? = nil) -> [AIBackend] {
        AIBackendID.allCases.map { id in
            let provider: any AIProvider
            switch id {
            case .openai: provider = OpenAIProvider()
            case .codex: provider = CodexProvider()
            case .anthropic: provider = HTTPAIProvider(kind: .anthropic)
            case .gateway: provider = HTTPAIProvider(kind: .gateway)
            case .grok: provider = HTTPAIProvider(kind: .grok)
            }
            var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sora")
            if let windowID {
                folder.appendPathComponent("AgentWindows/" + windowID.uuidString, isDirectory: true)
            }
            if let tabID { folder.appendPathComponent("Tasks/" + tabID.uuidString, isDirectory: true) }
            // Legacy files remain untouched; windows never overwrite each other.
            let filename = id == .openai ? "ask.json" : "ask-\(id.rawValue).json"
            return AIBackend(id: id, provider: provider,
                             credentials: KeychainAICredentialStore(account: id.rawValue),
                             conversations: FileAIConversationStore(url: folder.appendingPathComponent(filename)))
        }
    }
}

/// Startup health uses delivered PCM, since an audio engine can run with a
/// faulted voice-processing unit. Ordinary microphone silence is not an error.
struct RealtimeCaptureHealth {
    enum Action: Equatable {
        case healthy, retryWithoutVoiceProcessing, captureFailed
    }

    private var receivedBuffer = false
    private var receivedSignal = false

    mutating func record(hasSignal: Bool) {
        receivedBuffer = true
        receivedSignal = receivedSignal || hasSignal
    }

    func action(usesVoiceProcessing: Bool) -> Action {
        if usesVoiceProcessing && !receivedSignal { return .retryWithoutVoiceProcessing }
        return receivedBuffer ? .healthy : .captureFailed
    }
}
