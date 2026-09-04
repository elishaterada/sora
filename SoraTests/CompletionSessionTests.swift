import XCTest

final class CompletionSessionTests: XCTestCase {
    func testAcceptsTabSuffixAndKeepsTracking() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-complete-session-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CommandHistoryStore(url: url)
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let run = try XCTUnwrap(CommandRunFactory.make(
            command: "git status",
            cwd: cwd,
            exitCode: 0,
            durationNanos: 1,
            now: Date()
        ))
        try store.record(run)

        let session = CompletionSession()
        XCTAssertEqual(
            session.handleKeyDown(keyCode: 5, characters: "g", modifiers: []),
            .passThrough
        )
        XCTAssertEqual(
            session.handleKeyDown(keyCode: 34, characters: "i", modifiers: []),
            .passThrough
        )
        session.refresh(cwd: cwd, history: store)
        XCTAssertEqual(session.suggestion?.insertSuffix, "t status")

        XCTAssertEqual(
            session.handleKeyDown(keyCode: PromptEvent.tab, characters: "\t", modifiers: []),
            .accept("t status")
        )
        XCTAssertEqual(session.buffer.text, "git status")
    }

    func testTabWithoutSuggestionPassesThrough() {
        let session = CompletionSession()
        XCTAssertEqual(
            session.handleKeyDown(keyCode: PromptEvent.tab, characters: "\t", modifiers: []),
            .passThrough
        )
        XCTAssertFalse(session.buffer.isTracking)
    }

    func testEmptyPromptPredictsNextCommand() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-predict-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CommandHistoryStore(url: url)
        let cwd = URL(fileURLWithPath: "/tmp/project")
        try store.recordTransition(
            previous: "git status",
            next: "git push",
            cwd: cwd,
            at: Date()
        )

        let session = CompletionSession()
        session.rememberSuccessfulCommand("git status")
        session.refresh(cwd: cwd, history: store)
        XCTAssertEqual(session.suggestion?.insertSuffix, "git push")
        XCTAssertEqual(session.suggestion?.source, .prediction)
        XCTAssertEqual(
            session.handleKeyDown(keyCode: PromptEvent.tab, characters: "\t", modifiers: []),
            .accept("git push")
        )
        XCTAssertEqual(session.buffer.text, "git push")
    }

    func testEscapeDismissesPredictionUntilNextCommand() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-predict-esc-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CommandHistoryStore(url: url)
        let cwd = URL(fileURLWithPath: "/tmp/project")
        try store.recordTransition(
            previous: "pwd",
            next: "ls",
            cwd: cwd,
            at: Date()
        )
        let session = CompletionSession()
        session.rememberSuccessfulCommand("pwd")
        session.refresh(cwd: cwd, history: store)
        XCTAssertEqual(session.suggestion?.insertSuffix, "ls")
        XCTAssertEqual(
            session.handleKeyDown(keyCode: PromptEvent.escape, characters: "\u{1b}", modifiers: []),
            .passThrough
        )
        session.refresh(cwd: cwd, history: store)
        XCTAssertNil(session.suggestion)
        session.rememberSuccessfulCommand("pwd")
        session.refresh(cwd: cwd, history: store)
        XCTAssertEqual(session.suggestion?.insertSuffix, "ls")
    }
}
