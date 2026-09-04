import Foundation

struct AIMessage: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Status: String, Codable, Sendable { case complete, streaming, stopped, failed }

    var id = UUID()
    let role: Role
    var text: String
    var status: Status = .complete
}

struct AIRequest: Sendable {
    let model: String
    let messages: [AIMessage]
}

enum AIEvent: Equatable, Sendable {
    case text(String)
    case completed
}

/// Sora owns conversations and cancellation. Adapters only translate requests
/// and streaming events; this Ask slice exposes no terminal or filesystem tools.
protocol AIProvider: Sendable {
    func events(for request: AIRequest, credential: String) -> AsyncThrowingStream<AIEvent, Error>
}

enum AIError: LocalizedError {
    case disabled, missingKey, invalidModel, incompleteStream, malformedResponse
    case requestFailed(Int)
    case responseFailed
    case contextTooLarge

    var errorDescription: String? {
        switch self {
        case .disabled: return "Enable AI in Setup to send a question."
        case .missingKey: return "Add your API key in Setup."
        case .invalidModel: return "Enter a model ID in Setup."
        case .incompleteStream: return "The answer was interrupted before it finished. Try again."
        case .malformedResponse: return "The provider returned an unreadable response."
        case .requestFailed(401): return "The API key was rejected. Update it in Setup."
        case .requestFailed(429): return "The provider's usage or rate limit was reached. Check your API billing or try later."
        case .requestFailed(let status): return "The AI request failed (HTTP \(status)). Check the model ID and API access."
        case .responseFailed: return "The provider could not finish the answer. Try again."
        case .contextTooLarge: return "This conversation is too long. Start a new conversation to continue."
        }
    }
}
