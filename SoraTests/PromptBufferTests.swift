import XCTest

final class PromptBufferTests: XCTestCase {
    func testInsertBackspaceAndReset() {
        var buffer = PromptBuffer()
        buffer.apply(.insert("gi"))
        buffer.apply(.insert("t"))
        XCTAssertEqual(buffer.text, "git")
        buffer.apply(.backspace)
        XCTAssertEqual(buffer.text, "gi")
        buffer.apply(.reset)
        XCTAssertEqual(buffer.text, "")
        XCTAssertTrue(buffer.isTracking)
    }

    func testStopTrackingDropsFurtherInserts() {
        var buffer = PromptBuffer()
        buffer.apply(.insert("ls"))
        buffer.apply(.stopTracking)
        buffer.apply(.insert("a"))
        XCTAssertEqual(buffer.text, "")
        XCTAssertFalse(buffer.isTracking)
        buffer.apply(.reset)
        buffer.apply(.insert("pwd"))
        XCTAssertEqual(buffer.text, "pwd")
    }

    func testPromptEventMapsPrintableAndResetKeys() {
        XCTAssertEqual(
            PromptEvent.from(keyCode: 17, characters: "t", modifiers: []),
            .insert("t")
        )
        XCTAssertEqual(
            PromptEvent.from(keyCode: PromptEvent.delete, characters: "", modifiers: []),
            .backspace
        )
        XCTAssertEqual(
            PromptEvent.from(keyCode: PromptEvent.returnKey, characters: "\r", modifiers: []),
            .reset
        )
        XCTAssertEqual(
            PromptEvent.from(keyCode: PromptEvent.upArrow, characters: "", modifiers: []),
            .stopTracking
        )
        XCTAssertEqual(
            PromptEvent.from(keyCode: PromptEvent.tab, characters: "\t", modifiers: []),
            .stopTracking
        )
        XCTAssertEqual(
            PromptEvent.from(keyCode: 8, characters: "c", modifiers: [.control]),
            .reset
        )
        XCTAssertNil(PromptEvent.from(keyCode: 8, characters: "c", modifiers: [.command]))
        XCTAssertTrue(PromptEvent.isAcceptKey(keyCode: PromptEvent.tab, modifiers: []))
        XCTAssertTrue(PromptEvent.isAcceptKey(keyCode: PromptEvent.rightArrow, modifiers: []))
        XCTAssertFalse(PromptEvent.isAcceptKey(keyCode: PromptEvent.tab, modifiers: [.shift]))
    }

    func testPromptEventTracksUnicodeQuestions() {
        XCTAssertEqual(
            PromptEvent.from(keyCode: 0, characters: "¿Cómo?", modifiers: []),
            .insert("¿Cómo?")
        )
    }

    func testQuestionRoutingRecoversAfterActualControlCharacters() {
        for character in ["\u{03}", "\u{15}"] {
            let session = CompletionSession()
            session.stopTracking()
            _ = session.handleKeyDown(keyCode: 8, characters: character, modifiers: [.control])
            _ = session.handleKeyDown(keyCode: 0, characters: "Help me find a large files", modifiers: [])
            XCTAssertTrue(session.buffer.isTracking)
            XCTAssertEqual(
                PromptIntentClassifier.submission(for: session.buffer.text),
                .agent("Help me find a large files")
            )
        }
    }

    func testMouseFocusOnEmptyReadyPromptResumesTrackingForAgentRouting() {
        let session = CompletionSession()
        session.stopTracking()
        XCTAssertFalse(session.buffer.isTracking)

        session.applyMouseFocus(isShellPromptReady: true)
        XCTAssertTrue(session.buffer.isTracking)
        XCTAssertEqual(session.buffer.text, "")

        _ = session.handleKeyDown(keyCode: 4, characters: "Help me find the largest files", modifiers: [])
        XCTAssertEqual(
            PromptIntentClassifier.submission(for: session.buffer.text),
            .agent("Help me find the largest files")
        )
    }

    func testMouseFocusAfterTypedTextKeepsTrackingForAgentRouting() {
        let session = CompletionSession()
        _ = session.handleKeyDown(keyCode: 0, characters: "Help me", modifiers: [])
        session.applyMouseFocus(isShellPromptReady: true)
        XCTAssertTrue(session.buffer.isTracking)
        _ = session.handleKeyDown(keyCode: 0, characters: " find files", modifiers: [])
        XCTAssertEqual(session.buffer.text, "Help me find files")
        XCTAssertEqual(
            PromptIntentClassifier.submission(for: session.buffer.text),
            .agent("Help me find files")
        )
    }

    func testYoutubeHelpLineRoutesToAgentNotShell() {
        let line = "Help me download youtube video https://www.youtube.com/watch?v=bOC3DisEOfg as mp4 into ~/Downloads"
        XCTAssertEqual(PromptIntentClassifier.intent(for: line), .agent)
        XCTAssertEqual(PromptIntentClassifier.submission(for: line), .agent(line))
    }

    func testPartialControlEditsDoNotTrackOnlyTheQuestionSuffix() {
        for character in ["a", "e", "k", "w", "\u{01}", "\u{05}", "\u{0b}", "\u{17}"] {
            XCTAssertEqual(
                PromptEvent.from(keyCode: 0, characters: character, modifiers: [.control]),
                .stopTracking
            )
        }
    }
}
