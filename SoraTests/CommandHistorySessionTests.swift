import XCTest
import AppKit

final class CommandHistorySessionTests: XCTestCase {
    private let entries = ["git status", "git diff", "git log"].enumerated().map {
        CommandHistoryEntry(command: $0.element, lastUsed: Date(timeIntervalSince1970: Double(30 - $0.offset)))
    }

    func testMinimumHeightWithTallDraftAlwaysShowsASelectableRow() {
        for lines in 1...6 {
            let inputHeight = CGFloat(112 + (lines - 1) * 24)
            let height = CommandHistoryLayout.panelHeight(preferred: 308, pane: 280, input: inputHeight)
            let layout = CommandHistoryLayout(height: height)
            XCTAssertGreaterThanOrEqual(layout.rows, 30, "Hidden history for a \(lines)-line draft")
            XCTAssertLessThanOrEqual(height + inputHeight, 280)
            XCTAssertGreaterThanOrEqual(layout.footer, 18)
        }
        let full = CommandHistoryLayout(height: 308)
        XCTAssertEqual(full.rows, 240)
        XCTAssertEqual(full.header, 35)
        XCTAssertEqual(full.footer, 33)
    }

    func testNavigationStartsWithLatestClampsAtOldestAndReturnsToDraft() {
        let session = loadedSession(draft: "git ")
        XCTAssertEqual(session.selected?.command, "git status")
        session.move(older: true)
        XCTAssertEqual(session.selected?.command, "git diff")
        session.move(older: true)
        session.move(older: true)
        XCTAssertEqual(session.selected?.command, "git log")
        XCTAssertEqual(session.draft, "git ")
        for _ in 0..<3 { session.move(older: false) }
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selected)
        XCTAssertEqual(session.draft, "git ")
    }

    func testMouseChoiceAndCancelNeverReplaceSavedMultilineUnicodeDraft() {
        let draft = "echo 日本語\nprintf 'a\\nb'"
        let session = loadedSession(draft: draft)
        session.select(index: 2)
        XCTAssertEqual(session.selected?.command, "git log")
        session.select(index: -1)
        XCTAssertEqual(session.selected?.command, "git log")
        session.dismiss()
        XCTAssertEqual(session.draft, draft)
        XCTAssertNil(session.selected)
    }

    func testSlowLookupKeepsArrowNavigationResponsive() {
        let worker = DispatchQueue(label: "sora.history-tests.slow")
        let gate = DispatchSemaphore(value: 0)
        worker.async { gate.wait() }
        let session = CommandHistorySession(worker: worker)
        let loaded = expectation(description: "history loaded")
        session.onChange = {
            if session.isPresented && !session.isLoading { loaded.fulfill() }
        }
        let entries = entries
        session.open(draft: "git") { _ in entries }
        session.move(older: true)
        session.move(older: true)
        XCTAssertTrue(session.isLoading)
        XCTAssertNil(session.selected)
        gate.signal()
        wait(for: [loaded], timeout: 5)
        session.onChange = nil
        XCTAssertEqual(session.selected?.command, "git log")
    }

    func testDismissedLookupCannotReopenOrOverwriteANewerQuery() {
        let worker = DispatchQueue(label: "sora.history-tests.stale")
        let gate = DispatchSemaphore(value: 0)
        worker.async { gate.wait() }
        let session = CommandHistorySession(worker: worker)
        let loaded = expectation(description: "new query loaded")
        session.onChange = {
            if session.isPresented && !session.isLoading {
                XCTAssertEqual(session.selected?.command, "pwd")
                loaded.fulfill()
            }
        }
        session.open(draft: "git") { _ in self.entries }
        session.dismiss()
        session.open(draft: "pw") { _ in [.init(command: "pwd", lastUsed: Date())] }
        gate.signal()
        wait(for: [loaded], timeout: 5)
        session.onChange = nil
        XCTAssertEqual(session.draft, "pw")
    }

    func testEmptyAndFailedQueriesKeepDraftAndExposeTheirState() {
        for shouldFail in [false, true] {
            let session = CommandHistorySession()
            let loaded = expectation(description: "query complete")
            session.onChange = { if !session.isLoading { loaded.fulfill() } }
            session.open(draft: "missing") { _ in
                if shouldFail { throw CommandHistoryStoreError.executeFailed("test failure") }
                return []
            }
            wait(for: [loaded], timeout: 5)
            session.onChange = nil
            XCTAssertTrue(session.isPresented)
            XCTAssertNil(session.selected)
            XCTAssertEqual(session.errorMessage != nil, shouldFail)
            session.move(older: false)
            XCTAssertFalse(session.isPresented)
            XCTAssertEqual(session.draft, "missing")
        }
    }

    func testOnlyUnmodifiedInputArrowsOpenHistory() {
        for key in [PromptEvent.upArrow, PromptEvent.downArrow] {
            XCTAssertTrue(opens(key))
            XCTAssertTrue(opens(key, draft: "git s", cursor: 5))
            XCTAssertFalse(opens(key, ready: false))
            XCTAssertFalse(opens(key, integration: false))
            for mods: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
                XCTAssertFalse(opens(key, mods: mods))
            }
        }
        XCTAssertFalse(opens(PromptEvent.leftArrow))
    }

    func testArrowsWithinMultilineInputRemainShellCursorMovement() {
        let draft = "one\ntwo\nthree"
        XCTAssertTrue(opens(PromptEvent.upArrow, draft: draft, cursor: 2))
        XCTAssertFalse(opens(PromptEvent.upArrow, draft: draft, cursor: 5))
        XCTAssertFalse(opens(PromptEvent.downArrow, draft: draft, cursor: 5))
        XCTAssertTrue(opens(PromptEvent.downArrow, draft: draft, cursor: 10))
        XCTAssertTrue(opens(PromptEvent.upArrow, draft: "日本\n語", cursor: 2))
        XCTAssertFalse(opens(PromptEvent.upArrow, draft: "日本\n語", cursor: 3))
    }

    private func loadedSession(draft: String) -> CommandHistorySession {
        let session = CommandHistorySession()
        let loaded = expectation(description: "history loaded")
        session.onChange = { if !session.isLoading { loaded.fulfill() } }
        session.open(draft: draft) { _ in self.entries }
        wait(for: [loaded], timeout: 5)
        session.onChange = nil
        return session
    }

    private func opens(_ key: UInt16, mods: NSEvent.ModifierFlags = [], ready: Bool = true,
                       integration: Bool = true, draft: String = "", cursor: Int = 0) -> Bool {
        CommandHistoryInput.opensHistory(keyCode: key, modifiers: mods, promptReady: ready,
                                        hasShellIntegration: integration, draft: draft, cursorOffset: cursor)
    }
}
