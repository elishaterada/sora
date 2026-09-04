import Foundation

/// HTTP providers share transport/cancellation, not wire schemas.
struct HTTPAIProvider: AIProvider {
    let kind: AIBackendID
    var session: URLSession = URLSession(configuration: .ephemeral)

    func events(for request: AIRequest, credential: String) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: Self.urlRequest(kind: kind, request: request, credential: credential))
                    guard let http = response as? HTTPURLResponse else { throw AIError.malformedResponse }
                    guard (200..<300).contains(http.statusCode) else { throw AIError.requestFailed(http.statusCode) }
                    guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
                    else { throw AIError.malformedResponse }
                    var decoder = ProviderStreamDecoder(kind: kind)
                    var completed = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in try decoder.parse(line: line) {
                            continuation.yield(event)
                            if event == .completed { completed = true }
                        }
                        if completed { break }
                    }
                    guard completed else { throw AIError.incompleteStream }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func urlRequest(kind: AIBackendID, request: AIRequest, credential: String) throws -> URLRequest {
        if kind == .openai { return try OpenAIProvider.urlRequest(request, credential: credential) }
        let endpoint: String
        switch kind {
        case .anthropic: endpoint = "https://api.anthropic.com/v1/messages"
        case .gateway: endpoint = "https://ai-gateway.vercel.sh/v1/chat/completions"
        case .grok: endpoint = "https://api.x.ai/v1/chat/completions"
        default: throw AIError.malformedResponse
        }
        var result = URLRequest(url: URL(string: endpoint)!)
        result.httpMethod = "POST"
        // xAI recommends a longer timeout for reasoning before the first token.
        result.timeoutInterval = kind == .grok ? 3600 : 60
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var messages = request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = ["model": request.model, "stream": true, "max_tokens": 4096]
        if kind == .anthropic {
            result.setValue(credential, forHTTPHeaderField: "x-api-key")
            result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["system"] = AIRequest.instructions
        } else {
            result.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            messages.insert(["role": "system", "content": AIRequest.instructions], at: 0)
        }
        body["messages"] = messages
        result.httpBody = try JSONSerialization.data(withJSONObject: body)
        return result
    }
}

struct ProviderStreamDecoder {
    let kind: AIBackendID
    private var endedNormally = false

    init(kind: AIBackendID) { self.kind = kind }

    mutating func parse(line: String) throws -> [AIEvent] {
        if kind == .openai { return try OpenAIProvider.parse(line: line).map { [$0] } ?? [] }
        guard line.hasPrefix("data:") else { return [] }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" {
            guard kind == .gateway || kind == .grok, endedNormally else { throw AIError.incompleteStream }
            return [.completed]
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            throw AIError.malformedResponse
        }
        if object["error"] != nil || object["type"] as? String == "error" { throw AIError.responseFailed }
        if kind == .anthropic {
            guard let type = object["type"] as? String else { throw AIError.malformedResponse }
            switch type {
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { return [.text(text)] }
            case "message_delta":
                if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String {
                    guard ["end_turn", "stop_sequence", "refusal"].contains(reason) else { throw AIError.incompleteStream }
                    endedNormally = true
                }
            case "message_stop":
                guard endedNormally else { throw AIError.incompleteStream }
                return [.completed]
            default: break
            }
            return []
        }
        guard let choices = object["choices"] as? [[String: Any]] else { throw AIError.malformedResponse }
        guard let choice = choices.first else { return [] } // Usage-only chunk.
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop" else { throw AIError.incompleteStream }
            endedNormally = true
        }
        let delta = choice["delta"] as? [String: Any]
        if let text = delta?["content"] as? String { return [.text(text)] }
        if let refusal = delta?["refusal"] as? String { return [.text(refusal)] }
        return []
    }
}
