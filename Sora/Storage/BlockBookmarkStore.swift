import Foundation
import Combine
import CryptoKit
import SQLite3

struct BlockBookmark: Equatable, Identifiable {
    let id: UUID
    let command: String
    let directory: String
    let sourceTabID: UUID
    let createdAt: Date
    let isExcerpt: Bool
}

/// Immutable saved copies, independent of terminal scrollback retention. SQLite
/// transactions serialize concurrent app instances without losing other saves.
final class BlockBookmarkStore: ObservableObject {
    static let outputByteLimit = 1_000_000
    static let maximumBookmarks = 200
    static var defaultURL: URL {
        WorkspaceWindowStore.defaultURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bookmarks/bookmarks.sqlite")
    }
    @Published private(set) var bookmarks: [BlockBookmark] = []
    @Published private(set) var errorMessage: String?
    let url: URL
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = BlockBookmarkStore.defaultURL) {
        self.url = url
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var handle: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            database = handle
            guard result == SQLITE_OK else { throw failure() }
            sqlite3_busy_timeout(database, 2_000)
            try transaction {
                let statement = try prepare("PRAGMA user_version;")
                guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); throw failure() }
                let version = sqlite3_column_int(statement, 0)
                sqlite3_finalize(statement)
                guard version == 0 || version == 1 else { throw BookmarkError.message("These bookmarks were saved by a newer Sora version. The file has been left unchanged.") }
                if version == 0 {
                    try execute("""
                        CREATE TABLE IF NOT EXISTS block_bookmarks (
                          id TEXT PRIMARY KEY NOT NULL, command TEXT NOT NULL,
                          directory TEXT NOT NULL, tab_id TEXT NOT NULL,
                          created_at REAL NOT NULL, excerpt INTEGER NOT NULL,
                          output TEXT NOT NULL, digest TEXT NOT NULL UNIQUE
                        );
                        PRAGMA user_version = 1;
                        """)
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try reload()
        } catch {
            errorMessage = error.localizedDescription
            if let database { sqlite3_close(database) }
            database = nil
        }
    }
    deinit { if let database { sqlite3_close(database) } }

    static func excerpt(_ text: String) -> (text: String, truncated: Bool) {
        OutputSearchText.clipped(text, byteLimit: outputByteLimit)
    }

    @discardableResult
    func save(command: String, output: String, directory: String, tabID: UUID) throws -> UUID {
        guard !command.isEmpty, command.utf8.count <= 100_000, directory.utf8.count <= 4096 else {
            throw BookmarkError.message("This command is too large to bookmark.")
        }
        let copy = Self.excerpt(output)
        let digest = SHA256.hash(data: try JSONEncoder().encode([tabID.uuidString, command, copy.text, String(copy.truncated)]))
            .map { String(format: "%02x", $0) }.joined()
        do {
            let id: UUID = try transaction {
                let existing = try prepare("SELECT id FROM block_bookmarks WHERE digest = ?;")
                defer { sqlite3_finalize(existing) }
                try bind(digest, at: 1, to: existing)
                let existingResult = sqlite3_step(existing)
                if existingResult == SQLITE_ROW, let id = UUID(uuidString: text(existing, 0)) { return id }
                guard existingResult == SQLITE_DONE else { throw failure() }
                let count = try prepare("SELECT COUNT(*) FROM block_bookmarks;")
                defer { sqlite3_finalize(count) }
                guard sqlite3_step(count) == SQLITE_ROW else { throw failure() }
                guard sqlite3_column_int(count, 0) < Self.maximumBookmarks else {
                    throw BookmarkError.message("You have 200 bookmarks. Delete a saved copy before adding another.")
                }
                let id = UUID(), statement = try prepare("INSERT INTO block_bookmarks VALUES (?, ?, ?, ?, ?, ?, ?, ?);")
                defer { sqlite3_finalize(statement) }
                for (offset, value) in [id.uuidString, command, directory, tabID.uuidString].enumerated() {
                    try bind(value, at: Int32(offset + 1), to: statement)
                }
                sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
                sqlite3_bind_int(statement, 6, copy.truncated ? 1 : 0)
                try bind(copy.text, at: 7, to: statement)
                try bind(digest, at: 8, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
                return id
            }
            try reload()
            errorMessage = nil
            return id
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    func output(for id: UUID) throws -> String {
        let statement = try prepare("SELECT output FROM block_bookmarks WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_bytes(statement, 0) <= Self.outputByteLimit else { throw BookmarkError.message("This saved output exceeds the supported size.") }
            return text(statement, 0)
        case SQLITE_DONE: throw BookmarkError.message("This bookmark was deleted in another window or app. Refresh the list.")
        default: throw failure()
        }
    }
    func delete(_ id: UUID) throws {
        do {
            let statement = try prepare("DELETE FROM block_bookmarks WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try reload()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    func refresh() {
        do { try reload(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func reload() throws {
        let statement = try prepare("SELECT id, command, directory, tab_id, created_at, excerpt FROM block_bookmarks ORDER BY created_at DESC, id DESC LIMIT 201;")
        defer { sqlite3_finalize(statement) }
        var result: [BlockBookmark] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = UUID(uuidString: text(statement, 0)), let tab = UUID(uuidString: text(statement, 3)),
                      result.count < Self.maximumBookmarks else { throw BookmarkError.message("The bookmark catalog contains invalid records. Its file has been left unchanged.") }
                result.append(BlockBookmark(id: id, command: text(statement, 1), directory: text(statement, 2), sourceTabID: tab,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), isExcerpt: sqlite3_column_int(statement, 5) != 0))
            case SQLITE_DONE: bookmarks = result; return
            default: throw failure()
            }
        }
    }
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do { let result = try operation(); try execute("COMMIT;"); return result }
        catch { try? execute("ROLLBACK;"); throw error }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard database != nil else { throw BookmarkError.message(errorMessage ?? "Bookmarks are unavailable.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard database != nil else { throw BookmarkError.message(errorMessage ?? "Bookmarks are unavailable.") }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), Self.transient) }
        guard result == SQLITE_OK else { throw failure() }
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    private func failure() -> Error {
        BookmarkError.message(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Bookmarks are unavailable.")
    }
    enum BookmarkError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
