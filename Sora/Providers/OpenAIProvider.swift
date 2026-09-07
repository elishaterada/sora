import Foundation

struct OpenAIProvider: AIProvider {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func events(for request: AIRequest, credential: String) -> AsyncThrowingStream<AIEvent, Error> {
        HTTPAIProvider(kind: .openai, session: session).events(for: request, credential: credential)
    }

    static func urlRequest(_ request: AIRequest, credential: String) throws -> URLRequest {
        var result = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        result.httpMethod = "POST"
        result.timeoutInterval = 60
        result.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        result.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.model,
            "stream": true,
            "store": false,
            "max_output_tokens": 4096,
            "instructions": AIRequest.instructions,
            "input": try request.messages.map { ["role": $0.role.rawValue, "content": try $0.contentForProvider()] }
        ])
        return result
    }

    static func parse(line: String) throws -> AIEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let type = object["type"] as? String else { throw AIError.malformedResponse }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = object["delta"] as? String else { throw AIError.malformedResponse }
            return .text(delta)
        case "response.completed": return .completed
        case "response.failed", "error": throw ProviderAPIError.parse(provider: "OpenAI API", object: object)
        case "response.incomplete": throw ProviderAPIError.parse(provider: "OpenAI API", object: object)
        default: return nil
        }
    }
}
