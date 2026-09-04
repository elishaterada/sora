import XCTest

final class CompletionEngineTests: XCTestCase {
    func testPrefersSameCwdHistoryOverFrequency() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let other = URL(fileURLWithPath: "/tmp/other")
        let now = Date(timeIntervalSince1970: 1_000)
        let suggestion = CompletionEngine.suggest(
            line: "gi",
            cwd: cwd,
            now: now,
            history: [
                HistoryCommandStat(
                    command: "git push",
                    lastCwd: other,
                    frequency: 20,
                    lastUsed: now,
                    sameCwdCount: 0
                ),
                HistoryCommandStat(
                    command: "git status",
                    lastCwd: cwd,
                    frequency: 2,
                    lastUsed: now.addingTimeInterval(-100),
                    sameCwdCount: 2
                ),
            ],
            pathMatches: []
        )
        XCTAssertEqual(suggestion?.insertSuffix, "t status")
        XCTAssertEqual(suggestion?.source, .history)
    }

    func testHistorySuffixKeepsLeadingSpaceBeforeNextToken() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let now = Date(timeIntervalSince1970: 1_000)
        let suggestion = CompletionEngine.suggest(
            line: "git",
            cwd: cwd,
            now: now,
            history: [
                HistoryCommandStat(
                    command: "git status",
                    lastCwd: cwd,
                    frequency: 3,
                    lastUsed: now,
                    sameCwdCount: 3
                ),
            ],
            pathMatches: []
        )
        XCTAssertEqual(suggestion?.insertSuffix, " status")
        XCTAssertTrue(suggestion?.insertSuffix.hasPrefix(" ") == true)
    }

    func testPathLikeTokenBeatsHistory() throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-complete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )

        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent("src/app", isDirectory: true),
            withIntermediateDirectories: true
        )

        let historyPrefix = CompletionEngine.suggest(
            line: "ls s",
            cwd: cwd,
            now: Date(),
            history: [
                HistoryCommandStat(
                    command: "ls src",
                    lastCwd: cwd,
                    frequency: 4,
                    lastUsed: Date(),
                    sameCwdCount: 4
                ),
            ],
            pathMatches: PathCompleter.matches(token: "s", cwd: cwd)
        )
        XCTAssertEqual(historyPrefix?.insertSuffix, "rc")
        XCTAssertEqual(historyPrefix?.source, .history)

        let cwdFilePrefix = CompletionEngine.suggest(
            line: "ls sr",
            cwd: cwd,
            now: Date(),
            history: [],
            pathMatches: PathCompleter.matches(token: "sr", cwd: cwd)
        )
        XCTAssertEqual(cwdFilePrefix?.insertSuffix, "c/")
        XCTAssertEqual(cwdFilePrefix?.source, .path)

        let pathFirst = CompletionEngine.suggest(
            line: "ls src/",
            cwd: cwd,
            now: Date(),
            history: [
                HistoryCommandStat(
                    command: "ls src/old",
                    lastCwd: cwd,
                    frequency: 4,
                    lastUsed: Date(),
                    sameCwdCount: 4
                ),
            ],
            pathMatches: PathCompleter.matches(token: "src/", cwd: cwd)
        )
        XCTAssertEqual(pathFirst?.insertSuffix, "app/")
        XCTAssertEqual(pathFirst?.source, .path)
    }

    func testRequiresTwoCharactersForHistory() {
        let cwd = URL(fileURLWithPath: "/tmp")
        let suggestion = CompletionEngine.suggest(
            line: "g",
            cwd: cwd,
            now: Date(),
            history: [
                HistoryCommandStat(
                    command: "git status",
                    lastCwd: cwd,
                    frequency: 1,
                    lastUsed: Date(),
                    sameCwdCount: 1
                ),
            ],
            pathMatches: []
        )
        XCTAssertNil(suggestion)
    }
}
