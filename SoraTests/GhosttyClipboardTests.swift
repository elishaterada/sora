import AppKit
import GhosttyKit
import XCTest

final class GhosttyClipboardTests: XCTestCase {
    func testWriteAndReadPlainTextRoundTrip() {
        let pasteboard = GhosttyClipboard.pasteboard(for: GHOSTTY_CLIPBOARD_STANDARD)
        GhosttyClipboard.writePlainText("hello from sora", to: pasteboard)
        XCTAssertEqual(GhosttyClipboard.plainText(from: pasteboard), "hello from sora")
    }

    func testSelectionPasteboardIsDistinct() {
        let general = GhosttyClipboard.pasteboard(for: GHOSTTY_CLIPBOARD_STANDARD)
        let selection = GhosttyClipboard.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION)
        XCTAssertFalse(general === selection)
    }
}
