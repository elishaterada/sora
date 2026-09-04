import AppKit
import CoreText
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
        // ime_point x is the cell midpoint; ghost text starts at the leading edge.
        let origin = GhosttyInput.ghostTextOrigin(
            imeX: 20,
            imeY: 40,
            viewHeight: 500,
            cellWidth: 8
        )
        XCTAssertEqual(origin.x, 16)
        XCTAssertEqual(origin.y, 460)
    }

    func testGhostTextCellWidthPrefersRescaledWhenCloseToAdvance() {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        let advance = GhosttyInput.monospaceAdvance(font: font)
        XCTAssertGreaterThan(advance, 0)
        // Exact match in point space: CELL_SIZE already matches IME height.
        let width = GhosttyInput.ghostTextCellWidth(
            imeHeight: 20,
            cellSize: NSSize(width: advance, height: 20),
            font: font
        )
        XCTAssertEqual(width, advance, accuracy: 0.001)
    }

    func testGhostTextCellWidthFallsBackToAdvanceWhenCELLSIZEDisgrees() {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        let advance = GhosttyInput.monospaceAdvance(font: font)
        let width = GhosttyInput.ghostTextCellWidth(
            imeHeight: 20,
            cellSize: NSSize(width: advance * 3, height: 20),
            font: font
        )
        XCTAssertEqual(width, advance, accuracy: 0.001)
    }

    func testGhostTextBaselineCentersEmBoxInCell() {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let cellHeight = (ascent + descent) * 1.12
        let baseline = GhosttyInput.ghostTextBaseline(cellHeight: cellHeight, font: font)
        XCTAssertEqual(baseline, (cellHeight - ascent + descent) / 2, accuracy: 0.001)
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertLessThan(baseline, cellHeight)
    }
}
