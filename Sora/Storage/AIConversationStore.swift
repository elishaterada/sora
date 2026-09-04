import Foundation

protocol AIConversationStore {
    func load() throws -> [AIMessage]
    func save(_ messages: [AIMessage]) throws
}

/// Only Ask messages live here. Credentials are exclusively in Keychain.
struct FileAIConversationStore: AIConversationStore {
    let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sora/ask.json")) {
        self.url = url
    }

    func load() throws -> [AIMessage] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AIMessage].self, from: data).map { message in
            var message = message
            if message.status == .streaming { message.status = .stopped }
            return message
        }
    }

    func save(_ messages: [AIMessage]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(messages)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
