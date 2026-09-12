import Foundation

protocol AIConversationStore {
    func load() throws -> [AIMessage]
    func save(_ messages: [AIMessage]) throws
}

/// Only Ask messages live here. Credentials are exclusively in Keychain.
struct FileAIConversationStore: AIConversationStore {
    let url: URL
    private struct Checkpoint: Codable {
        let version: Int
        let messages: [AIMessage]
    }

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sora/ask.json")) {
        self.url = url
    }

    func load() throws -> [AIMessage] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let messages: [AIMessage]
        if let checkpoint = try? decoder.decode(Checkpoint.self, from: data) {
            guard checkpoint.version == 1 else {
                throw NSError(domain: "Sora.Task", code: 1, userInfo: [NSLocalizedDescriptionKey: "This task was saved by an unsupported version of Sora."])
            }
            messages = checkpoint.messages
        } else { messages = try decoder.decode([AIMessage].self, from: data) }
        return messages.map { message in
            var message = message
            if ["running", "fetching"].contains(message.commandState ?? "") { message.commandState = "stopped" }
            if message.commandProposal?.status == .approved, message.commandResult == nil { message.commandState = "stopped" }
            if message.status == .streaming { message.status = .stopped }
            return message
        }
    }

    func save(_ messages: [AIMessage]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Checkpoint(version: 1, messages: messages))
        // Set private permissions before content is written, including first save.
        let temporary = directory.appendingPathComponent(".task-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
}
