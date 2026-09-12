import Foundation

/// An explicitly attached snapshot, never live terminal access or permission.
struct TerminalOutputAttachment: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case selection, commandBlock }
    static let byteLimit = 16_384
    let id: UUID
    let source: Source
    let command: String?
    let directory: String?
    let text: String
    let capturedAt: Date
    let isExcerpt: Bool
    var title: String { source == .selection ? "Selected terminal output" : "Command output" }

    init(source: Source, command: String? = nil, directory: String? = nil, text: String, capturedAt: Date = Date(), isExcerpt: Bool = false) {
        id = UUID()
        self.source = source
        self.command = command.map { Self.bounded($0, bytes: 1024) }
        self.directory = directory.map { Self.bounded($0, bytes: 1024) }
        self.text = Self.bounded(text, bytes: Self.byteLimit)
        self.capturedAt = capturedAt
        self.isExcerpt = isExcerpt || text.utf8.count > Self.byteLimit
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        var data = Data(value.utf8.prefix(bytes))
        while !data.isEmpty {
            if let text = String(data: data, encoding: .utf8) { return text }
            data.removeLast()
        }
        return ""
    }
}
