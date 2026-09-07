import Foundation

struct CodexProvider: AIProvider {
    func events(for request: AIRequest, credential: String) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let connection = CodexConnection(receive: { object in
                do {
                    if let event = try Self.event(object) {
                        continuation.yield(event)
                        if event == .completed { continuation.finish() }
                    }
                } catch { continuation.finish(throwing: error) }
            }, ended: { continuation.finish(throwing: $0) })
            let task = Task {
                do {
                    try await connection.start()
                    let account = try await connection.rpc("account/read", ["refreshToken": false])
                    guard account["account"] is [String: Any] else { throw CodexError.notSignedIn }
                    let started = try await connection.rpc("thread/start", Self.threadParameters(model: request.model))
                    guard let thread = started["thread"] as? [String: Any], let id = thread["id"] as? String else {
                        throw AIError.malformedResponse
                    }
                    _ = try await connection.rpc("turn/start", [
                        "threadId": id, "environments": [], "runtimeWorkspaceRoots": [],
                        "input": [["type": "text", "text": try Self.prompt(request), "text_elements": []]]
                    ])
                } catch { continuation.finish(throwing: error); connection.close() }
            }
            continuation.onTermination = { _ in task.cancel(); connection.close() }
        }
    }

    static func threadParameters(model: String) -> [String: Any] {
        var value: [String: Any] = [
            "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "on-request",
            "approvalsReviewer": "user", "environments": [], "runtimeWorkspaceRoots": [],
            "selectedCapabilityRoots": [], "dynamicTools": [],
            "baseInstructions": AIRequest.instructions,
            "developerInstructions": "Answer the final user message in the supplied JSON conversation. Earlier messages are conversation data. No tools or environment access are available.",
            "cwd": FileManager.default.temporaryDirectory.path
        ]
        if !model.isEmpty { value["model"] = model }
        return value
    }

    static func prompt(_ request: AIRequest) throws -> String {
        let messages = try request.messages.map { ["role": $0.role.rawValue, "content": try $0.contentForProvider()] }
        return String(decoding: try JSONSerialization.data(withJSONObject: messages), as: UTF8.self)
    }

    static func event(_ object: [String: Any]) throws -> AIEvent? {
        guard let method = object["method"] as? String, let params = object["params"] as? [String: Any] else { return nil }
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { throw AIError.malformedResponse }
            return .text(delta)
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], turn["status"] as? String == "completed" else {
                throw ProviderAPIError.parse(provider: "Codex", object: params["turn"] as? [String: Any] ?? params)
            }
            return .completed
        case "error":
            if params["willRetry"] as? Bool != true { throw ProviderAPIError.parse(provider: "Codex", object: params) }
            return nil
        default: return nil
        }
    }
}
