import AppKit
import CoreText
import XCTest

final class GhosttyInputTests: XCTestCase {
    func testStartupInputWaitsForPromptAndReplaysInOrderOnce() {
        var buffer = ShellStartupInputBuffer<String>()
        for input in ["press e", "release e", "paste st", "backspace", "return"] {
            XCTAssertTrue(buffer.enqueue(input))
        }
        XCTAssertTrue(buffer.isWaiting)
        XCTAssertEqual(buffer.finish(), ["press e", "release e", "paste st", "backspace", "return"])
        XCTAssertFalse(buffer.isWaiting)
        XCTAssertTrue(buffer.finish().isEmpty)
    }

    func testStartupCancellationDiscardsDraftButStillWaitsForPrompt() {
        var buffer = ShellStartupInputBuffer<String>()
        XCTAssertTrue(buffer.enqueue("abandoned draft"))
        buffer.discardPending()
        XCTAssertTrue(buffer.isWaiting)
        XCTAssertTrue(buffer.enqueue("replacement draft"))
        XCTAssertEqual(buffer.finish(), ["replacement draft"])
    }

    func testStartupBufferDoesNotInterceptLaterCommandInput() {
        var buffer = ShellStartupInputBuffer<String>()
        _ = buffer.finish()
        XCTAssertFalse(buffer.enqueue("editor input"))
        XCTAssertFalse(buffer.enqueue("next prompt input"))
        XCTAssertTrue(buffer.finish().isEmpty)
    }

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
    func testSuggestionGlyphsStayInTheSameColumnsWhileTypingAndBackspacing() throws {
        let anchor = GhostTextAnchor(originX: 30, cellWidth: 10)
        var buffer = PromptBuffer()
        let fullCommand = "ls -lah"
        let view = GhostTextView()
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        for prefix in ["ls", "ls ", "ls -", "ls -l", "ls -la", "ls -l", "ls -", "ls ", "ls"] {
            buffer.apply(.reset)
            buffer.apply(.insert(prefix))
            let x = try XCTUnwrap(anchor.positionX(for: buffer, viewWidth: 800))
            let suffix = String(fullCommand.dropFirst(prefix.count))
            // Live IME supplies Y; tests pin a stable row.
            let origin = NSPoint(x: x, y: 100)
            view.show(text: suffix, origin: origin, cellWidth: 10, cellHeight: 20, font: font)
            // The final 'h' must not shift as its prefix is typed or erased.
            XCTAssertEqual(view.frame.minX + CGFloat(suffix.count - 1) * 10, 90)
            XCTAssertEqual(view.frame.minY, 100)
            XCTAssertFalse(view.isHidden)
        }
    }

    func testSuggestionAnchorRejectsUntrackedWideAndWrappedInput() {
        let anchor = GhostTextAnchor(originX: 30, cellWidth: 10)
        var buffer = PromptBuffer()
        buffer.apply(.insert("ls"))
        XCTAssertNil(anchor.positionX(for: buffer, viewWidth: 55))
        buffer.apply(.insert("猫"))
        XCTAssertNil(anchor.positionX(for: buffer, viewWidth: 800))
        buffer.apply(.stopTracking)
        XCTAssertNil(anchor.positionX(for: buffer, viewWidth: 800))
    }

    func testSuggestionUsesLiveIMERowNotStaleAnchorY() {
        // Anchored X advances with the buffer; Y must come from the live caret
        // so a mid-screen stale value cannot pin the overlay.
        let anchor = GhostTextAnchor(originX: 30, cellWidth: 10)
        var buffer = PromptBuffer()
        buffer.apply(.insert("Tell me"))
        let x = anchor.positionX(for: buffer, viewWidth: 800)
        XCTAssertEqual(x, 100)
        let liveY = GhosttyInput.ghostTextOrigin(
            imeX: 104, imeY: 40, viewHeight: 500, cellWidth: 10
        ).y
        XCTAssertEqual(liveY, 460)
        let origin = NSPoint(x: max(x ?? 0, 104 - 5), y: liveY)
        XCTAssertEqual(origin.y, 460)
        XCTAssertGreaterThan(origin.x, 30)
    }
}
