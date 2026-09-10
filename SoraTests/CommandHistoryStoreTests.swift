import XCTest

final class CommandHistoryStoreTests: XCTestCase {
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
