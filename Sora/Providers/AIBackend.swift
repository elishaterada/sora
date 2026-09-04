import Foundation

enum AIBackendID: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai, codex, anthropic, gateway
    var id: String { rawValue }
    var name: String {
        switch self {
        case .openai: return "OpenAI API"
        case .codex: return "Codex"
        case .anthropic: return "Anthropic API"
        case .gateway: return "Vercel AI Gateway"
        }
    }
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5.4-mini"
        case .codex: return "" // Codex chooses from its account's model catalog.
        case .anthropic: return "claude-sonnet-4-6"
        case .gateway: return "openai/gpt-5.4"
        }
    }
    var needsKey: Bool { self != .codex }
    var disclosure: String {
        switch self {
        case .openai: return "This OpenAI conversation is sent to OpenAI."
        case .codex: return "This Codex conversation uses your Codex sign-in."
        case .anthropic: return "This Anthropic conversation is sent to Anthropic."
        case .gateway: return "This Gateway conversation is sent through Vercel to the selected model provider."
        }
    }
}

struct AIBackend {
    let id: AIBackendID
    let provider: any AIProvider
    let credentials: any AICredentialStore
    let conversations: any AIConversationStore

    static func live() -> [AIBackend] {
        AIBackendID.allCases.map { id in
            let provider: any AIProvider
            switch id {
            case .openai: provider = OpenAIProvider()
            case .codex: provider = CodexProvider()
            case .anthropic: provider = HTTPAIProvider(kind: .anthropic)
            case .gateway: provider = HTTPAIProvider(kind: .gateway)
            }
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sora")
            // Preserve the existing OpenAI conversation at its original path.
            let filename = id == .openai ? "ask.json" : "ask-\(id.rawValue).json"
            return AIBackend(id: id, provider: provider,
                             credentials: KeychainAICredentialStore(account: id.rawValue),
                             conversations: FileAIConversationStore(url: folder.appendingPathComponent(filename)))
        }
    }
}
