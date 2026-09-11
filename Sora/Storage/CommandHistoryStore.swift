import Foundation
import SQLite3

struct CommandHistoryEntry: Equatable {
    let command: String
    let lastUsed: Date
}

enum CommandHistoryStoreError: Error, LocalizedError {
    case openFailed(String)
    case executeFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Failed to open command history: \(message)"
        case .executeFailed(let message):
            return "Command history query failed: \(message)"
        }
    }
}

/// SQLite-backed command history. One file per user; not a secrets store.
final class CommandHistoryStore: ObservableObject {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @Published private(set) var recent: [CommandRun] = []

    private var database: OpaquePointer?
    private let url: URL

    static func applicationSupportURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("Sora", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    convenience init() throws {
        try self.init(url: try Self.applicationSupportURL())
    }

    init(url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = url.path.withCString { path in
            sqlite3_open_v2(path, &handle, flags, nil)
        }
        guard status == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw CommandHistoryStoreError.openFailed(Self.message(from: handle))
        }
        database = handle
        try execute(
            """
            CREATE TABLE IF NOT EXISTS command_runs (
                id TEXT PRIMARY KEY NOT NULL,
                command TEXT NOT NULL,
                cwd TEXT NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL NOT NULL,
                exit_code INTEGER NOT NULL,
                duration_ns INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_command_runs_finished_at
                ON command_runs(finished_at DESC);
            CREATE INDEX IF NOT EXISTS idx_command_runs_command
                ON command_runs(command);
            CREATE TABLE IF NOT EXISTS command_transitions (
                id TEXT PRIMARY KEY NOT NULL,
                previous TEXT NOT NULL,
                next TEXT NOT NULL,
                cwd TEXT NOT NULL,
                finished_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_command_transitions_previous
                ON command_transitions(previous, finished_at DESC);
            """
        )
        // Older rows have no reliable tab identity. Preserve them in the global
        // archive without assigning them to an arbitrary tab.
        let columns = try prepare("PRAGMA table_info(command_runs);")
        var hasTabID = false
        while sqlite3_step(columns) == SQLITE_ROW {
            if let name = sqlite3_column_text(columns, 1), String(cString: name) == "tab_id" {
                hasTabID = true
            }
        }
        sqlite3_finalize(columns)
        if !hasTabID {
            try execute("ALTER TABLE command_runs ADD COLUMN tab_id TEXT;")
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_command_runs_tab ON command_runs(tab_id, finished_at DESC);")
        try reload()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func record(_ run: CommandRun, tabID: UUID? = nil) throws {
        try insert(run, tabID: tabID)
        try reload()
    }

    func insert(_ run: CommandRun, tabID: UUID? = nil) throws {
        let sql = """
            INSERT INTO command_runs
                (id, command, cwd, started_at, finished_at, exit_code, duration_ns, tab_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, run.id.uuidString)
        try bindText(statement, index: 2, run.command)
        try bindText(statement, index: 3, run.cwd.path)
        guard sqlite3_bind_double(statement, 4, run.startedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
        guard sqlite3_bind_double(statement, 5, run.finishedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
        guard sqlite3_bind_int(statement, 6, Int32(run.exitCode)) == SQLITE_OK else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
        guard sqlite3_bind_int64(statement, 7, Int64(bitPattern: run.durationNanos)) == SQLITE_OK else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
        if let tabID { try bindText(statement, index: 8, tabID.uuidString) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
    }

    func reload() throws {
        recent = try recent(limit: 200)
    }

    /// One row per command, optionally restricted to a stable workspace tab.
    /// Prefix metacharacters are literal; failed commands remain recallable.
    func recall(prefix: String, tabID: UUID? = nil, limit: Int = 200) throws -> [CommandHistoryEntry] {
        guard limit > 0 else { return [] }
        let statement = try prepare("""
            SELECT command, MAX(finished_at) AS last_used
            FROM command_runs
            WHERE command LIKE ? ESCAPE '\\'
                AND (? IS NULL OR tab_id = ?)
            GROUP BY command
            ORDER BY last_used DESC, command ASC
            LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, Self.likePrefix(prefix))
        if let tabID {
            try bindText(statement, index: 2, tabID.uuidString)
            try bindText(statement, index: 3, tabID.uuidString)
        }
        sqlite3_bind_int(statement, 4, Int32(clamping: limit))
        var entries: [CommandHistoryEntry] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let command = sqlite3_column_text(statement, 0) else { continue }
                entries.append(CommandHistoryEntry(
                    command: String(cString: command),
                    lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                ))
            case SQLITE_DONE: return entries
            default: throw CommandHistoryStoreError.executeFailed(message)
            }
        }
    }

    func prefixStats(prefix: String, cwd: URL, limit: Int = 80) throws -> [HistoryCommandStat] {
        guard !prefix.isEmpty else { return [] }
        let sql = """
            SELECT
                r.command,
                r.cwd,
                s.frequency,
                s.last_used,
                s.same_cwd_count
            FROM (
                SELECT
                    command,
                    COUNT(*) AS frequency,
                    MAX(finished_at) AS last_used,
                    SUM(CASE WHEN cwd = ? THEN 1 ELSE 0 END) AS same_cwd_count
                FROM command_runs
                WHERE command LIKE ? ESCAPE '\\'
                GROUP BY command
                ORDER BY frequency DESC, last_used DESC
                LIMIT ?
            ) AS s
            JOIN command_runs AS r
                ON r.command = s.command AND r.finished_at = s.last_used;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, cwd.path)
        try bindText(statement, index: 2, Self.likePrefix(prefix))
        sqlite3_bind_int(statement, 3, Int32(limit))

        var stats: [HistoryCommandStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let command = sqlite3_column_text(statement, 0),
                  let cwdText = sqlite3_column_text(statement, 1)
            else {
                continue
            }
            stats.append(HistoryCommandStat(
                command: String(cString: command),
                lastCwd: URL(fileURLWithPath: String(cString: cwdText)),
                frequency: Int(sqlite3_column_int(statement, 2)),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                sameCwdCount: Int(sqlite3_column_int(statement, 4))
            ))
        }
        return stats
    }

    func recordTransition(previous: String, next: String, cwd: URL, at: Date = Date()) throws {
        guard !previous.isEmpty, !next.isEmpty else { return }
        let sql = """
            INSERT INTO command_transitions (id, previous, next, cwd, finished_at)
            VALUES (?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, UUID().uuidString)
        try bindText(statement, index: 2, previous)
        try bindText(statement, index: 3, next)
        try bindText(statement, index: 4, cwd.path)
        guard sqlite3_bind_double(statement, 5, at.timeIntervalSince1970) == SQLITE_OK else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
    }

    func transitionStats(previous: String, cwd: URL, limit: Int = 40) throws -> [TransitionStat] {
        guard !previous.isEmpty else { return [] }
        let sql = """
            SELECT
                r.next,
                r.cwd,
                s.frequency,
                s.last_used,
                s.same_cwd_count
            FROM (
                SELECT
                    next,
                    COUNT(*) AS frequency,
                    MAX(finished_at) AS last_used,
                    SUM(CASE WHEN cwd = ? THEN 1 ELSE 0 END) AS same_cwd_count
                FROM command_transitions
                WHERE previous = ?
                GROUP BY next
                ORDER BY frequency DESC, last_used DESC
                LIMIT ?
            ) AS s
            JOIN command_transitions AS r
                ON r.previous = ? AND r.next = s.next AND r.finished_at = s.last_used;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, cwd.path)
        try bindText(statement, index: 2, previous)
        sqlite3_bind_int(statement, 3, Int32(limit))
        try bindText(statement, index: 4, previous)

        var stats: [TransitionStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let next = sqlite3_column_text(statement, 0),
                  let cwdText = sqlite3_column_text(statement, 1)
            else {
                continue
            }
            stats.append(TransitionStat(
                next: String(cString: next),
                lastCwd: URL(fileURLWithPath: String(cString: cwdText)),
                frequency: Int(sqlite3_column_int(statement, 2)),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                sameCwdCount: Int(sqlite3_column_int(statement, 4))
            ))
        }
        return stats
    }

    static func likePrefix(_ prefix: String) -> String {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }

    func recent(limit: Int) throws -> [CommandRun] {
        let sql = """
            SELECT id, command, cwd, started_at, finished_at, exit_code, duration_ns
            FROM command_runs
            ORDER BY finished_at DESC
            LIMIT ?;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var runs: [CommandRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let run = row(from: statement) else { continue }
            runs.append(run)
        }
        return runs
    }

    private func row(from statement: OpaquePointer) -> CommandRun? {
        guard let idText = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idText)),
              let command = sqlite3_column_text(statement, 1),
              let cwd = sqlite3_column_text(statement, 2)
        else {
            return nil
        }
        let duration = UInt64(bitPattern: sqlite3_column_int64(statement, 6))
        return CommandRun(
            id: id,
            command: String(cString: command),
            cwd: URL(fileURLWithPath: String(cString: cwd)),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            finishedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            exitCode: Int(sqlite3_column_int(statement, 5)),
            durationNanos: duration
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sql.withCString { pointer in
            sqlite3_prepare_v2(database, pointer, -1, &statement, nil)
        }
        guard status == SQLITE_OK, let statement else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
        return statement
    }

    private func bindText(_ statement: OpaquePointer, index: Int32, _ value: String) throws {
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard status == SQLITE_OK else {
            throw CommandHistoryStoreError.executeFailed(message)
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        if let error {
            let text = String(cString: error)
            sqlite3_free(error)
            if status != SQLITE_OK {
                throw CommandHistoryStoreError.executeFailed(text)
            }
        } else if status != SQLITE_OK {
            throw CommandHistoryStoreError.executeFailed(message)
        }
    }

    private var message: String {
        Self.message(from: database)
    }

    private static func message(from database: OpaquePointer?) -> String {
        if let database, let pointer = sqlite3_errmsg(database) {
            return String(cString: pointer)
        }
        return "unknown SQLite error"
    }
}
