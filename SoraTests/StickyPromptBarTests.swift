import XCTest

final class StickyPromptBarTests: XCTestCase {
    func testInputGrowsToHalfPaneThenKeepsOverflowScrollable() {
        XCTAssertEqual(StickyPromptBarModel.visibleLineCount(total: 3, maximumHeight: 400), 3)
        XCTAssertEqual(StickyPromptBarModel.visibleLineCount(total: 100, maximumHeight: 400), 13)
        XCTAssertEqual(StickyPromptBarModel.visibleLineCount(total: 100, maximumHeight: 200), 4)
        XCTAssertEqual(StickyPromptBarModel.visibleLineCount(total: 1, maximumHeight: 400), 1)
        XCTAssertEqual(StickyPromptBarModel.visibleLineCount(total: 100, maximumHeight: 112), 1)
    }

    func testSelectionCopiesOriginalBufferWithoutVisualWraps() {
        XCTAssertEqual(StickyPromptBarModel.selectedText("abcdef", range: 1..<5), "bcde")
        XCTAssertEqual(StickyPromptBarModel.selectedText("ab\n😀cd", range: 1..<5), "b\n😀c")
        XCTAssertEqual(StickyPromptBarModel.selectedText("abc", range: 2..<2), "")
    }

    func testClickOffsetsPreserveWrappedAndUnicodePositions() {
        let result = StickyPromptBarModel.wrap("abcde\nf", cursorOffset: 0, width: 3) { CGFloat($0.count) }
        XCTAssertEqual(result.starts, [0, 3, 6])
        XCTAssertEqual(StickyPromptBarModel.hitOffset(in: "a😀b", x: 1.6) { CGFloat($0.count) }, 2)
        XCTAssertEqual(StickyPromptBarModel.hitOffset(in: "abc", x: -1) { CGFloat($0.count) }, 0)
        XCTAssertEqual(StickyPromptBarModel.hitOffset(in: "abc", x: 99) { CGFloat($0.count) }, 3)
    }

    func testWrappingPreservesInputAndTracksCursor() {
        let wrapped = StickyPromptBarModel.wrap("abcdef\ngh", cursorOffset: 5, width: 3) { CGFloat($0.count) }
        XCTAssertEqual(wrapped.lines, ["abc", "def", "gh"])
        XCTAssertEqual(wrapped.cursorRow, 1)
        XCTAssertEqual(wrapped.cursorPrefix, "de")
        let unicode = StickyPromptBarModel.wrap("a😀e\u{301}", cursorOffset: 4, width: 1) { CGFloat($0.count) }
        XCTAssertEqual(unicode.lines, ["a", "😀", "e\u{301}"])
        XCTAssertEqual(unicode.cursorRow, 2)
        let boundary = StickyPromptBarModel.wrap("abcd", cursorOffset: 3, width: 3) { CGFloat($0.count) }
        XCTAssertEqual(boundary.cursorRow, 1)
        XCTAssertEqual(boundary.cursorPrefix, "")
    }

    func testLongPromptUsesBoundedTextMeasurementWork() {
        let text = String(repeating: "abcdefghij", count: 1000)
        var measuredCharacters = 0
        let wrapped = StickyPromptBarModel.wrap(text, cursorOffset: text.count, width: 80) {
            measuredCharacters += $0.count
            return CGFloat($0.count)
        }
        XCTAssertEqual(wrapped.lines.joined(), text)
        XCTAssertTrue(wrapped.lines.allSatisfy { $0.count <= 80 })
        XCTAssertLessThan(measuredCharacters, text.count * 12)
    }

    func testEmptyLinesAndWideUnicodeKeepCursorPositions() {
        let empty = StickyPromptBarModel.wrap("", cursorOffset: 0, width: 1) { CGFloat($0.count) }
        XCTAssertEqual(empty.lines, [""])
        let line = "a\n\n😀b\n"
        let result = StickyPromptBarModel.wrap(line, cursorOffset: 4, width: 1) { CGFloat($0.count) }
        XCTAssertEqual(result.lines, ["a", "", "😀", "b", ""])
        XCTAssertEqual(result.starts, [0, 2, 3, 4, 6])
        XCTAssertEqual(result.cursorRow, 3)
        XCTAssertEqual(result.cursorPrefix, "")
    }

    func testInputNeverAppendsSuggestionToShellText() {
        XCTAssertEqual(StickyPromptBarModel.inputText(buffer: "ls -lah", prediction: "ls"), "ls -lah")
        XCTAssertEqual(StickyPromptBarModel.inputText(buffer: "ls -lah", prediction: nil), "ls -lah")
        XCTAssertEqual(StickyPromptBarModel.inputText(buffer: "", prediction: "ls"), "ls")
        XCTAssertEqual(StickyPromptBarModel.inputText(buffer: "", prediction: nil), "")
    }

    func testLivePromptWhenScrollbarAtBottom() {
        XCTAssertTrue(
            StickyPromptBarModel.isViewingLivePrompt(total: 100, offset: 80, len: 20)
        )
        XCTAssertTrue(
            StickyPromptBarModel.isViewingLivePrompt(total: 0, offset: 0, len: 0)
        )
    }

    func testScrolledAwayFromLivePrompt() {
        XCTAssertFalse(
            StickyPromptBarModel.isViewingLivePrompt(total: 100, offset: 10, len: 20)
        )
    }

    func testDisplayPathUsesHomeTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(StickyPromptBarModel.displayPath(for: home), "~")
        let child = home.appendingPathComponent("Downloads", isDirectory: true)
        XCTAssertEqual(StickyPromptBarModel.displayPath(for: child), "~/Downloads")
    }
}
