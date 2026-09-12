import AppKit
import CoreText
import QuartzCore
import XCTest

final class GhosttyInputTests: XCTestCase {
    @MainActor
    func testImpactStrengthClampsAndScalesAllPatterns() {
        XCTAssertEqual(TypingImpact.normalizedStrength(.nan), 1)
        XCTAssertEqual(TypingImpact.normalizedStrength(.infinity), 1)
        XCTAssertEqual(TypingImpact.normalizedStrength(-5), 0.25)
        XCTAssertEqual(TypingImpact.normalizedStrength(8), 2)
        for index in TypingImpact.patterns.indices {
            for isReturn in [false, true] {
                let standard = TypingImpact.poses(isReturn: isReturn, patternIndex: index)
                for strength in [0.25, 0.5, 1.0, 2.0] {
                    let adjusted = TypingImpact.poses(isReturn: isReturn, patternIndex: index, strength: strength)
                    for (original, scaled) in zip(standard, adjusted) {
                        XCTAssertEqual(scaled.angle, original.angle * strength, accuracy: 0.00001)
                        XCTAssertEqual(scaled.x, original.x * strength, accuracy: 0.00001)
                        XCTAssertEqual(scaled.y, original.y * strength, accuracy: 0.00001)
                    }
                    XCTAssertEqual(adjusted.last, TypingImpact.Pose())
                }
            }
        }
    }

    @MainActor
    func testTenTypingSoundsDecodeAndHaveDistinctBoundedWaveforms() throws {
        XCTAssertEqual(TypingSound.allCases.count, 10)
        XCTAssertEqual(TypingSound.resolve("unknown-old-value"), .crispClack)
        var distinct = Set<Data>()
        for profile in TypingSound.allCases {
            let data = profile.waveData()
            distinct.insert(data)
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertNotNil(NSSound(data: data), profile.title)
            let bytes = Array(data.dropFirst(44))
            let samples = stride(from: 0, to: bytes.count, by: 2).map {
                Int(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
            }
            XCTAssertEqual(samples.first, 0)
            XCTAssertEqual(samples.last, 0)
            let peak = try XCTUnwrap(samples.map(abs).max())
            XCTAssertGreaterThan(peak, 10000)
            XCTAssertLessThan(peak, 27000)
            XCTAssertNotEqual(data, profile.waveData(variant: 1))
            let returnData = profile.waveData(isReturn: true)
            XCTAssertGreaterThan(returnData.count, data.count)
            XCTAssertNotNil(NSSound(data: returnData))
        }
        XCTAssertEqual(distinct.count, 10)
    }

    @MainActor
    func testTypingSoundPlayerCanLoadAndSwitchEveryProfile() {
        let player = TypingSoundPlayer()
        for profile in TypingSound.allCases {
            player.configure(profile: profile, volume: 0)
            XCTAssertNil(player.errorMessage)
        }
        player.configure(profile: .crispClack, volume: .nan)
        XCTAssertNil(player.errorMessage)
        player.stop()
    }

    @MainActor
    func testTypingImpactNeverMovesWindowAndReturnOverridesTyping() async throws {
        let window = NSWindow(contentRect: NSRect(x: 150.25, y: 180.75, width: 980, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = try XCTUnwrap(window.contentView)
        let impact = TypingImpact()
        let originalFrame = window.frame
        for index in 0..<100 {
            impact.strike(view: view, isReturn: false, now: Double(index))
            XCTAssertEqual(window.frame, originalFrame)
            XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(view.layer).sublayerTransform))
        }
        impact.strike(view: view, isReturn: true, now: 100)
        XCTAssertEqual(view.layer?.animation(forKey: TypingImpact.animationKey)?.duration, 0.65)
        // A following character must not swallow the bigger Return impact.
        impact.strike(view: view, isReturn: false, now: 100.01)
        XCTAssertEqual(view.layer?.animation(forKey: TypingImpact.animationKey)?.duration, 0.65)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(view.layer).sublayerTransform))
        impact.stop()
        XCTAssertNil(view.layer?.animation(forKey: TypingImpact.animationKey))
    }

    @MainActor
    func testEightImpactPatternsVaryWithoutRepeatsAndSettleWithoutDrift() {
        var cycle = TypingImpact.PatternCycle()
        let choices = (0..<32).map { _ in cycle.next() }
        for start in stride(from: 0, to: choices.count, by: 8) {
            XCTAssertEqual(Set(choices[start..<start + 8]).count, 8)
        }
        for index in 1..<choices.count { XCTAssertNotEqual(choices[index], choices[index - 1]) }
        var trajectories = Set<[TypingImpact.Pose]>()
        let center = CGPoint(x: 490, y: 310)
        for index in TypingImpact.patterns.indices {
            let normal = TypingImpact.poses(isReturn: false, patternIndex: index)
            let strong = TypingImpact.poses(isReturn: true, patternIndex: index)
            trajectories.insert(strong)
            XCTAssertEqual(strong.first, TypingImpact.Pose())
            XCTAssertEqual(strong.last, TypingImpact.Pose())
            XCTAssertTrue(strong.contains { $0.angle > 0 })
            XCTAssertTrue(strong.contains { $0.angle < 0 })
            XCTAssertGreaterThan(strong.map { abs($0.angle) }.max()!, normal.map { abs($0.angle) }.max()! * 4)
            for pose in strong {
                let moved = center.applying(CATransform3DGetAffineTransform(TypingImpact.transform(pose: pose, center: center)))
                XCTAssertEqual(moved.x, center.x + pose.x, accuracy: 0.00001)
                XCTAssertEqual(moved.y, center.y + pose.y, accuracy: 0.00001)
                XCTAssertLessThanOrEqual(abs(pose.x), 8)
                XCTAssertLessThanOrEqual(abs(pose.y), 8)
            }
            let initial = TypingImpact.Pose(angle: 0.01, x: 2, y: -3)
            let interrupted = TypingImpact.poses(isReturn: true, patternIndex: index, initial: initial)
            XCTAssertEqual(interrupted.first, initial)
            XCTAssertEqual(interrupted.last, TypingImpact.Pose())
        }
        XCTAssertEqual(trajectories.count, 8)
    }

    func testTypingEffectsIgnoreShortcutsNavigationAndRepeat() {
        for modifiers: NSEvent.ModifierFlags in [.command, .control, [.command, .shift]] {
            XCTAssertFalse(TerminalPreferences.isTypingFeedbackEvent(characters: "a", modifiers: modifiers, isRepeat: false))
        }
        for characters in ["", "\u{1b}", "\t", "\u{f700}"] {
            XCTAssertFalse(TerminalPreferences.isTypingFeedbackEvent(characters: characters, modifiers: [], isRepeat: false))
        }
        XCTAssertFalse(TerminalPreferences.isTypingFeedbackEvent(characters: "a", modifiers: [], isRepeat: true))
        XCTAssertFalse(TerminalPreferences.isTypingFeedbackEvent(characters: nil, modifiers: [], isRepeat: false))
    }

    func testTypingEffectsAcceptTextAndEditingKeys() {
        for characters in ["a", "A", "é", "日本語", " ", "\r", "\u{3}", "\u{7f}"] {
            XCTAssertTrue(TerminalPreferences.isTypingFeedbackEvent(characters: characters, modifiers: [.shift], isRepeat: false))
        }
    }

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
