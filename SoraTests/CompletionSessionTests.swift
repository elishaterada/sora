import XCTest
import SQLite3

final class CompletionSessionTests: XCTestCase {
    func testSlowLookupDoesNotBlockTypingAndOnlyLatestResultIsApplied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CommandHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        for command in ["git status", "git push"] {
            try store.record(XCTUnwrap(CommandRunFactory.make(command: command, cwd: root, exitCode: 0, durationNanos: 1)))
        }
        let worker = DispatchQueue(label: "sora.tests.slow-completion")
        let gate = DispatchSemaphore(value: 0)
        worker.async { gate.wait() }
        let session = CompletionSession(worker: worker)
        session.handlePaste("git s")
        session.refreshAsync(cwd: root, history: store) { XCTFail("Stale suggestion was applied") }
        // The worker is deliberately blocked. Input must still be processed.
        _ = session.handleKeyDown(keyCode: PromptEvent.delete, characters: "", modifiers: [])
        session.handlePaste("p")
        XCTAssertEqual(session.buffer.text, "git p")
        XCTAssertNil(session.suggestion)
        let finished = expectation(description: "Latest suggestion")
        session.refreshAsync(cwd: root, history: store) {
            XCTAssertEqual(session.suggestion?.insertSuffix, "ush")
            finished.fulfill()
        }
        gate.signal()
        wait(for: [finished], timeout: 5)
    }

    func testLargeHistoryLookupRunsAsynchronously() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let store = try CommandHistoryStore(url: url)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
            INSERT INTO command_runs (id, command, cwd, started_at, finished_at, exit_code, duration_ns)
            SELECT CAST(x AS TEXT), 'git command-' || (x % 1000), '/tmp',
                   unixepoch(), unixepoch(), 0, 1 FROM n;
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let session = CompletionSession()
        session.handlePaste("git co")
        let done = expectation(description: "Large history lookup")
        let start = DispatchTime.now().uptimeNanoseconds
        session.refreshAsync(cwd: root, history: store) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(session.suggestion)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print("PERF 100000-history async lookup: \(milliseconds) ms wall time")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func testBurstCoalescesWithoutBlockingMainThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CommandHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let worker = DispatchQueue(label: "sora.tests.burst-completion")
        let gate = DispatchSemaphore(value: 0)
        worker.async { gate.wait() }
        let session = CompletionSession(worker: worker)
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<1000 {
            session.reset()
            session.handlePaste("command-\(i)")
            session.refreshAsync(cwd: root, history: store) { XCTFail("Obsolete burst result") }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("PERF completion enqueue: 1000 edits in \(elapsed) ms")
        XCTAssertEqual(session.buffer.text, "command-999")
        let done = expectation(description: "Burst drained")
        session.refreshAsync(cwd: root, history: store) { done.fulfill() }
        gate.signal()
        wait(for: [done], timeout: 5)
    }

    func testEditingInvalidatesSuggestionBeforeTabCanAcceptIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CommandHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        try store.record(XCTUnwrap(CommandRunFactory.make(command: "git status", cwd: root, exitCode: 0, durationNanos: 1)))
        let session = CompletionSession()
        session.handlePaste("git s")
        session.refresh(cwd: root, history: store)
        XCTAssertNotNil(session.suggestion)
        _ = session.handleKeyDown(keyCode: 0, characters: "x", modifiers: [])
        XCTAssertNil(session.suggestion)
        XCTAssertEqual(session.handleKeyDown(keyCode: PromptEvent.tab, characters: "\t", modifiers: []), .passThrough)
    }

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
