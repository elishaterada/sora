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
}
