import XCTest
import SQLite3

final class CommandHistoryStoreTests: XCTestCase {
    private func bookmarkURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sora-bookmarks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("bookmarks.sqlite")
    }

    func testBookmarksPersistLiteralOutputAndMergeIndependentSaves() throws {
        let url = try bookmarkURL(), tab = UUID()
        let first = BlockBookmarkStore(url: url), second = BlockBookmarkStore(url: url)
        XCTAssertNil(first.errorMessage)
        let output = "  café 🚀\n$(echo must-not-run)\0tail\n"
        let one = try first.save(command: "printf fixture", output: output, directory: "/tmp/project", tabID: tab)
        let two = try second.save(command: "printf second", output: "second output", directory: "/tmp", tabID: UUID())
        XCTAssertEqual(try second.save(command: "printf fixture", output: output, directory: "/tmp/project", tabID: tab), one)
        let reopened = BlockBookmarkStore(url: url)
        XCTAssertEqual(Set(reopened.bookmarks.map(\.id)), [one, two])
        XCTAssertEqual(try reopened.output(for: one), output)
        XCTAssertEqual(reopened.bookmarks.first(where: { $0.id == one })?.sourceTabID, tab)
        try first.delete(one)
        XCTAssertEqual(try second.output(for: two), "second output")
        XCTAssertThrowsError(try reopened.output(for: one))
        reopened.refresh()
        XCTAssertEqual(reopened.bookmarks.map(\.id), [two])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testBookmarkExcerptsAreExplicitAndKeepValidUnicode() throws {
        let url = try bookmarkURL(), store = BlockBookmarkStore(url: url)
        let prefix = String(repeating: "x", count: BlockBookmarkStore.outputByteLimit - 1)
        let original = prefix + "émore"
        let copy = BlockBookmarkStore.excerpt(original)
        XCTAssertEqual(copy.text, prefix)
        XCTAssertTrue(copy.truncated)
        let id = try store.save(command: "large log", output: original, directory: "/tmp", tabID: UUID())
        XCTAssertEqual(try store.output(for: id), prefix)
        XCTAssertTrue(try XCTUnwrap(store.bookmarks.first).isExcerpt)
        XCTAssertThrowsError(try store.save(command: "", output: "no command", directory: "", tabID: UUID()))
        XCTAssertEqual(store.bookmarks.count, 1)
    }

    func testBookmarkCapacityDoesNotDeleteEarlierCopies() throws {
        let store = BlockBookmarkStore(url: try bookmarkURL()), tab = UUID()
        for index in 0..<BlockBookmarkStore.maximumBookmarks {
            _ = try store.save(command: "fixture \(index)", output: "saved", directory: "/tmp", tabID: tab)
        }
        let before = store.bookmarks
        XCTAssertThrowsError(try store.save(command: "overflow", output: "new", directory: "/tmp", tabID: tab))
        XCTAssertEqual(store.bookmarks, before)
        XCTAssertEqual(BlockBookmarkStore(url: store.url).bookmarks, before)
    }

    func testFutureAndCorruptBookmarkFilesAreNotReplaced() throws {
        let url = try bookmarkURL()
        do {
            let store = BlockBookmarkStore(url: url)
            _ = try store.save(command: "saved", output: "keep me", directory: "/tmp", tabID: UUID())
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 99;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let bytes = try Data(contentsOf: url)
        let future = BlockBookmarkStore(url: url)
        XCTAssertTrue(future.errorMessage?.contains("newer Sora") == true)
        XCTAssertThrowsError(try future.save(command: "new", output: "no write", directory: "", tabID: UUID()))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let brokenURL = url.deletingLastPathComponent().appendingPathComponent("broken.sqlite")
        let broken = Data("not a database".utf8)
        try broken.write(to: brokenURL)
        let unreadable = BlockBookmarkStore(url: brokenURL)
        XCTAssertNotNil(unreadable.errorMessage)
        XCTAssertEqual(try Data(contentsOf: brokenURL), broken)
    }

    func testFuzzySearchScopesLiteralCharactersAndOlderCommands() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fuzzy-history-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CommandHistoryStore(url: url)
        let tab = UUID(), otherTab = UUID()
        let folder = URL(fileURLWithPath: "/tmp/project")
        func insert(_ command: String, _ tabID: UUID, _ cwd: URL, _ time: Double) throws {
            try store.insert(XCTUnwrap(CommandRunFactory.make(command: command, cwd: cwd, exitCode: 0,
                durationNanos: 1, now: Date(timeIntervalSince1970: time))), tabID: tabID)
        }
        try insert("git checkout release", tab, folder, 1)
        try insert("echo 100%_done", tab, folder, 2)
        try insert("echo 100Xdone", otherTab, folder, 3)
        try insert("echo Café 日本語", otherTab, URL(fileURLWithPath: "/usr"), 4)
        try insert("git checkout feature", otherTab, folder, 5)
        for index in 0..<250 { try insert("printf newer-\(index)", tab, folder, Double(index + 10)) }
        func search(_ query: String, _ scope: CommandHistoryScope) throws -> [String] {
            try store.search(query: query, scope: scope, tabID: tab, directory: folder).map(\.command)
        }
        XCTAssertEqual(try search("gcrls", .tab), ["git checkout release"])
        XCTAssertEqual(try search("rélease", .all), ["git checkout release"])
        XCTAssertEqual(try search("100%_", .all), ["echo 100%_done"])
        XCTAssertEqual(try search("cafe 日", .all), ["echo Café 日本語"])
        XCTAssertEqual(try search("cafe", .folder), [])
        XCTAssertEqual(try search("checkout", .folder).count, 2)
        XCTAssertEqual(try search("checkout", .tab), ["git checkout release"])
        XCTAssertEqual(try store.search(query: "", scope: .all, tabID: tab, directory: folder, limit: 2).count, 2)
    }

    func testFuzzyMatchHighlightsUnicodeAndRanksContiguousMatches() throws {
        let text = "echo 👩🏽‍💻 Café 日本語"
        let hit = try XCTUnwrap(FuzzySearch.match("cafe", in: text))
        XCTAssertEqual((text as NSString).substring(with: try XCTUnwrap(hit.ranges.first)), "Café")
        let fuzzy = try XCTUnwrap(FuzzySearch.match("e日語", in: text))
        XCTAssertEqual(fuzzy.ranges.map { (text as NSString).substring(with: $0) }, ["e", "日", "語"])
        XCTAssertGreaterThan(try XCTUnwrap(FuzzySearch.match("git", in: "git status")).score,
                             try XCTUnwrap(FuzzySearch.match("git", in: "go inspect things")).score)
        XCTAssertNil(FuzzySearch.match("zebra", in: text))
        XCTAssertEqual(FuzzySearch.match("  ", in: text)?.ranges, [])
    }

    func testTabRecallIsIsolatedAndSurvivesReopeningStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tab-history-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = UUID(), second = UUID()
        do {
            let store = try CommandHistoryStore(url: url)
            for (index, item) in [(first, "git status"), (second, "git diff"),
                                   (first, "false"), (second, "git status"),
                                   (first, "echo 100%_done")].enumerated() {
                let run = try XCTUnwrap(CommandRunFactory.make(
                    command: item.1, cwd: URL(fileURLWithPath: "/tmp"),
                    exitCode: item.1 == "false" ? 1 : 0, durationNanos: 1,
                    now: Date(timeIntervalSince1970: Double(index + 1))))
                try store.record(run, tabID: item.0)
            }
            XCTAssertEqual(try store.recall(prefix: "", tabID: first).map(\.command),
                           ["echo 100%_done", "false", "git status"])
            XCTAssertEqual(try store.recall(prefix: "", tabID: second).map(\.command), ["git status", "git diff"])
            XCTAssertEqual(try store.recall(prefix: "git", tabID: first).first?.lastUsed,
                           Date(timeIntervalSince1970: 1))
            XCTAssertEqual(try store.recall(prefix: "echo 100%_", tabID: first).map(\.command), ["echo 100%_done"])
            XCTAssertEqual(try store.recall(prefix: "", tabID: UUID()), [])
            XCTAssertEqual(try store.recall(prefix: "", tabID: first, limit: 1).map(\.command), ["echo 100%_done"])
            XCTAssertEqual(store.recent.count, 5)
        }
        let reopened = try CommandHistoryStore(url: url)
        XCTAssertEqual(try reopened.recall(prefix: "", tabID: first).map(\.command),
                       ["echo 100%_done", "false", "git status"])
    }

    func testLegacyHistoryRemainsGlobalAfterMigration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-history-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let sql = """
            CREATE TABLE command_runs (
                id TEXT PRIMARY KEY NOT NULL, command TEXT NOT NULL, cwd TEXT NOT NULL,
                started_at REAL NOT NULL, finished_at REAL NOT NULL,
                exit_code INTEGER NOT NULL, duration_ns INTEGER NOT NULL
            );
            INSERT INTO command_runs VALUES ('\(UUID().uuidString)', 'echo legacy', '/tmp', 1, 2, 0, 1);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let store = try CommandHistoryStore(url: url)
        XCTAssertEqual(try store.recall(prefix: "").map(\.command), ["echo legacy"])
        XCTAssertEqual(try store.recall(prefix: "", tabID: UUID()), [])
        XCTAssertEqual(store.recent.map(\.command), ["echo legacy"])
    }

    func testRecallUsesLatestDistinctCommandsAndLiteralPrefix() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-recall-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CommandHistoryStore(url: url)
        for (index, command) in ["git status", "git diff", "git status", "echo 100%_done", "echo 日本語\nprintf ok", "false"].enumerated() {
            try store.insert(XCTUnwrap(CommandRunFactory.make(
                command: command, cwd: URL(fileURLWithPath: index % 2 == 0 ? "/tmp" : "/usr"),
                exitCode: command == "false" ? 1 : 0, durationNanos: 1,
                now: Date(timeIntervalSince1970: Double(index + 1))
            )))
        }
        XCTAssertEqual(try store.recall(prefix: "").map(\.command),
                       ["false", "echo 日本語\nprintf ok", "echo 100%_done", "git status", "git diff"])
        let git = try store.recall(prefix: "git ")
        XCTAssertEqual(git.map(\.command), ["git status", "git diff"])
        XCTAssertEqual(git.first?.lastUsed, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(try store.recall(prefix: "echo 100%_").map(\.command), ["echo 100%_done"])
        XCTAssertEqual(try store.recall(prefix: "echo 100X"), [])
        XCTAssertEqual(try store.recall(prefix: "", limit: 1).map(\.command), ["false"])
        XCTAssertEqual(try store.recall(prefix: "", limit: 0), [])
        XCTAssertEqual(try CommandHistoryStore(url: url).recall(prefix: "git "), git)
    }

    func testInsertAndRecentOrder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try CommandHistoryStore(url: url)
        let first = try XCTUnwrap(CommandRunFactory.make(
            command: "echo one",
            cwd: URL(fileURLWithPath: "/tmp"),
            exitCode: 0,
            durationNanos: 1,
            now: Date(timeIntervalSince1970: 10)
        ))
        let second = try XCTUnwrap(CommandRunFactory.make(
            command: "false",
            cwd: URL(fileURLWithPath: "/usr"),
            exitCode: 1,
            durationNanos: 2,
            now: Date(timeIntervalSince1970: 20)
        ))
        try store.record(first)
        try store.record(second)

        XCTAssertEqual(store.recent.map(\.command), ["false", "echo one"])
        XCTAssertEqual(store.recent.map(\.exitCode), [1, 0])

        let reopened = try CommandHistoryStore(url: url)
        XCTAssertEqual(reopened.recent.map(\.command), ["false", "echo one"])
        XCTAssertEqual(reopened.recent.first?.cwd.path, "/usr")
    }

    func testPrefixStatsRanksByFrequencyAndSameCwd() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-history-prefix-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CommandHistoryStore(url: url)
        let project = URL(fileURLWithPath: "/tmp/project")
        let other = URL(fileURLWithPath: "/tmp/other")
        for (command, cwd, t) in [
            ("git status", project, 10.0),
            ("git status", project, 20.0),
            ("git push", other, 30.0),
            ("echo hi", project, 40.0),
        ] as [(String, URL, Double)] {
            let run = try XCTUnwrap(CommandRunFactory.make(
                command: command,
                cwd: cwd,
                exitCode: 0,
                durationNanos: 1,
                now: Date(timeIntervalSince1970: t)
            ))
            try store.record(run)
        }

        let stats = try store.prefixStats(prefix: "git", cwd: project)
        XCTAssertEqual(stats.map(\.command).sorted(), ["git push", "git status"])
        let status = try XCTUnwrap(stats.first { $0.command == "git status" })
        XCTAssertEqual(status.frequency, 2)
        XCTAssertEqual(status.sameCwdCount, 2)
        XCTAssertEqual(status.lastCwd.path, project.path)

        let escaped = try store.prefixStats(prefix: "echo%", cwd: project)
        XCTAssertEqual(escaped, [])
        XCTAssertEqual(CommandHistoryStore.likePrefix("a%b_c"), "a\\%b\\_c%")
    }

    func testTransitionStatsRanksBySameCwd() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-history-transition-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CommandHistoryStore(url: url)
        let project = URL(fileURLWithPath: "/tmp/project")
        let other = URL(fileURLWithPath: "/tmp/other")
        try store.recordTransition(
            previous: "git status",
            next: "git push",
            cwd: other,
            at: Date(timeIntervalSince1970: 10)
        )
        try store.recordTransition(
            previous: "git status",
            next: "git add -A",
            cwd: project,
            at: Date(timeIntervalSince1970: 20)
        )
        try store.recordTransition(
            previous: "git status",
            next: "git add -A",
            cwd: project,
            at: Date(timeIntervalSince1970: 30)
        )

        let stats = try store.transitionStats(previous: "git status", cwd: project)
        XCTAssertEqual(stats.map(\.next).sorted(), ["git add -A", "git push"])
        let add = try XCTUnwrap(stats.first { $0.next == "git add -A" })
        XCTAssertEqual(add.frequency, 2)
        XCTAssertEqual(add.sameCwdCount, 2)
        XCTAssertEqual(try store.transitionStats(previous: "ls", cwd: project), [])
    }
}
