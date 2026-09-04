import AppKit
import XCTest

final class GhosttyInputTests: XCTestCase {
    func testModsMapShiftControlOptionCommand() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = GhosttyInput.modBits(from: flags)
        XCTAssertNotEqual(mods & GhosttyInput.Mods.shift, 0)
        XCTAssertNotEqual(mods & GhosttyInput.Mods.ctrl, 0)
        XCTAssertNotEqual(mods & GhosttyInput.Mods.alt, 0)
        XCTAssertNotEqual(mods & GhosttyInput.Mods.command, 0)
    }

    func testModsMapEmpty() {
        XCTAssertEqual(GhosttyInput.modBits(from: []), GhosttyInput.Mods.none)
    }

    func testScrollPrecisionBit() {
        XCTAssertEqual(GhosttyInput.scrollPrecisionBit(true), 1)
        XCTAssertEqual(GhosttyInput.scrollPrecisionBit(false), 0)
    }

    func testSurfaceMousePointFlipsYToTopLeftOrigin() {
        let point = GhosttyInput.surfaceMousePoint(
            viewPoint: NSPoint(x: 10, y: 20),
            viewHeight: 500
        )
        XCTAssertEqual(point.x, 10)
        XCTAssertEqual(point.y, 480)
    }

    func testGhostTextOriginConvertsIMETopLeftToAppKit() {
        let origin = GhosttyInput.ghostTextOrigin(
            imeX: 20,
            imeY: 40,
            viewHeight: 500
        )
        XCTAssertEqual(origin.x, 20)
        XCTAssertEqual(origin.y, 460)
    }

    func testGhostTextBaselineCentersFontInCell() {
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        let cellHeight: CGFloat = 24
        let baseline = GhosttyInput.ghostTextBaseline(cellHeight: cellHeight, font: font)
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertLessThan(baseline, cellHeight)
        let extra = cellHeight - font.ascender + font.descender
        XCTAssertEqual(baseline, -font.descender + extra / 2)
    }
}
