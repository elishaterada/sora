import AppKit
import XCTest

final class GhosttyClipboardTests: XCTestCase {
    func testWriteAndReadPlainTextRoundTrip() {
        let pasteboard = NSPasteboard.general
        GhosttyClipboard.writePlainText("hello from sora", to: pasteboard)
        XCTAssertEqual(GhosttyClipboard.plainText(from: pasteboard), "hello from sora")
    }

    func testSelectionPasteboardIsDistinct() {
        XCTAssertFalse(NSPasteboard.general === GhosttyClipboard.selectionPasteboard)
    }
}
