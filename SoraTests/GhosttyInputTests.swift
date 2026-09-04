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
        // Match Ghostty AppKit: ime x is the IME rect's leading edge.
        let origin = GhosttyInput.ghostTextOrigin(
            imeX: 20,
            imeY: 40,
            viewHeight: 500,
            cellWidth: 8
        )
        XCTAssertEqual(origin.x, 20)
        XCTAssertEqual(origin.y, 460)
    }

    func testGhostTextCellWidthUsesCELLSIZEWhenHeightsAgree() {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        let width = GhosttyInput.ghostTextCellWidth(
            imeHeight: 20,
            cellSize: NSSize(width: 15, height: 20),
            font: font
        )
        XCTAssertEqual(width, 15, accuracy: 0.001)
    }

    func testGhostTextCellWidthRescalesWhenBackingUnitsDiffer() {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        // CELL_SIZE left in backing pixels while IME height is in points.
        let width = GhosttyInput.ghostTextCellWidth(
            imeHeight: 20,
            cellSize: NSSize(width: 30, height: 40),
            font: font
        )
        XCTAssertEqual(width, 15, accuracy: 0.001)
    }

    func testGhostTextCellWidthFallsBackWhenIMEHeightIsDoubleScaled() {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        let advance = GhosttyInput.monospaceAdvance(font: font).rounded()
        // CELL_SIZE already in points, but IME height still in backing pixels.
        let width = GhosttyInput.ghostTextCellWidth(
            imeHeight: 40,
            cellSize: NSSize(width: 15, height: 20),
            font: font
        )
        XCTAssertEqual(width, advance, accuracy: 0.001)
    }

    func testGhostTextBaselineCentersFaceInAdjustedCell() {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let faceHeight = ascent + descent + leading
        let cellHeight = faceHeight * 1.12
        let baseline = GhosttyInput.ghostTextBaseline(cellHeight: cellHeight, font: font)
        let expected = descent + leading / 2 + (cellHeight - faceHeight) / 2
        XCTAssertEqual(baseline, expected, accuracy: 0.001)
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertLessThan(baseline, cellHeight)
    }
}
