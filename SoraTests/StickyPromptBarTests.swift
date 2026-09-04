import XCTest

final class StickyPromptBarTests: XCTestCase {
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
