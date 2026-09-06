import XCTest

/// Option handling for the keystroke fallback buffer, used when a shell does
/// not report its edit line to Sora.
final class PromptLineRecoveryTests: XCTestCase {
    func testOptionPrintableKeepsTracking() {
        let session = CompletionSession()
        _ = session.handleKeyDown(keyCode: 0, characters: "Help me ", modifiers: [])
        _ = session.handleKeyDown(keyCode: 0, characters: "å", modifiers: [.option])
        XCTAssertTrue(session.buffer.isTracking)
        XCTAssertEqual(session.buffer.text, "Help me å")
    }

    func testOptionMetaWithoutTextStopsTracking() {
        XCTAssertEqual(
            PromptEvent.from(keyCode: 11, characters: "", modifiers: [.option]),
            .stopTracking
        )
    }
}
