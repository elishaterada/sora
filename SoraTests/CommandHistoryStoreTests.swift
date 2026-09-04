import XCTest

final class CommandHistoryStoreTests: XCTestCase {
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
}
