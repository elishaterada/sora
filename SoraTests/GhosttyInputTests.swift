import AppKit
import GhosttyKit
import XCTest

final class GhosttyInputTests: XCTestCase {
    func testModsMapShiftControlOptionCommand() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = GhosttyInput.mods(from: flags)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue, 0)
    }

    func testModsMapEmpty() {
        let mods = GhosttyInput.mods(from: [])
        XCTAssertEqual(mods.rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testScrollModsPrecisionBit() {
        XCTAssertEqual(GhosttyInput.scrollMods(precision: true), 1)
        XCTAssertEqual(GhosttyInput.scrollMods(precision: false), 0)
    }

    func testSurfaceMousePointFlipsYToTopLeftOrigin() {
        let point = GhosttyInput.surfaceMousePoint(
            viewPoint: NSPoint(x: 10, y: 20),
            viewHeight: 500
        )
        XCTAssertEqual(point.x, 10)
        XCTAssertEqual(point.y, 480)
    }
}
