import Foundation

struct OpenAIProvider: AIProvider {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func events(for request: AIRequest, credential: String) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: Self.urlRequest(request, credential: credential))
                    guard let http = response as? HTTPURLResponse else { throw AIError.malformedResponse }
                    guard (200..<300).contains(http.statusCode) else { throw AIError.requestFailed(http.statusCode) }
                    guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
                    else { throw AIError.malformedResponse }
                    var completed = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        // Responses emits one JSON object per data line. Other
                        // SSE fields and keepalive comments carry no text.
                        guard let event = try Self.parse(line: line) else { continue }
                        continuation.yield(event)
                        if event == .completed { completed = true; break }
                    }
                    guard completed else { throw AIError.incompleteStream }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
            "instructions": """
            You are Sora's terminal assistant for macOS and zsh. Help explain commands,
            troubleshoot errors, and propose concise, practical commands. You have no
            access to the terminal, files, or command history beyond what the user pastes
            into this conversation. Do not claim to run commands or inspect the computer.
            Explain consequential side effects before suggesting destructive commands.
            """,
            "input": request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
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
        case "response.failed", "error": throw AIError.responseFailed
        case "response.incomplete": throw AIError.incompleteStream
        default: return nil
        }
    }
}
