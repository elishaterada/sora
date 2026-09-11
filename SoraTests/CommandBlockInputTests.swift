import XCTest
import AppKit

final class CommandBlockInputTests: XCTestCase {
    func testStickyHeaderPreservesTerminalRGBAndResets() {
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        let styled = CommandHeaderStyle.attributedCommand("\u{1b}]10;rgb:cc/cc/cc\u{1b}\\\u{1b}[38;2;25;249;216mls\u{1b}[0m \u{1b}[38;2;255;117;181m-lah\u{1b}[0m  ", font: font)
        XCTAssertEqual(styled.string, "ls -lah")
        let teal = styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        XCTAssertEqual(teal.usingColorSpace(.sRGB)!.greenComponent, 249.0 / 255, accuracy: 0.001)
        let pink = styled.attribute(.foregroundColor, at: 3, effectiveRange: nil) as! NSColor
        XCTAssertEqual(pink.usingColorSpace(.sRGB)!.blueComponent, 181.0 / 255, accuracy: 0.001)
        XCTAssertEqual(styled.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, CommandHeaderStyle.foreground)
        XCTAssertEqual((styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
    }

    func testStickyHeaderPreservesTraitsAndUnicodeAcrossLines() {
        let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        let styled = CommandHeaderStyle.attributedCommand("  \u{1b}[1m\u{1b}[3mé😀\u{1b}[0m\n日本語  ", font: font)
        XCTAssertEqual(styled.string, "é😀\n日本語")
        let face = styled.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: face).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: face).contains(.italicFontMask))
        XCTAssertEqual(face.pointSize, 24)
        XCTAssertEqual(CommandHeaderStyle.singleLine(styled).string, "é😀 ↵ 日本語")
        XCTAssertEqual(CommandHeaderStyle.attributedCommand("\u{1b}[0m  ", font: font).length, 0)
    }

    func testStickyHeaderStripsHyperlinkMetadataAndIncompleteEscapes() {
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        let styled = CommandHeaderStyle.attributedCommand("\u{1b}]8;;https://example.com\u{7}echo\u{1b}]8;;\u{1b}\\ hi\u{1b}[38;2", font: font)
        XCTAssertEqual(styled.string, "echo hi")
    }

    func testOutputExportTrimsOnlyTrailingPadding() {
        XCTAssertEqual(CommandBlockText.output("  first\n\n  日本語\n(<1ms)    \n\n"), "  first\n\n  日本語\n(<1ms)")
        XCTAssertEqual(CommandBlockText.output("\n  indented  \nnext"), "\n  indented  \nnext")
        XCTAssertEqual(CommandBlockText.output("   \n"), "")
        XCTAssertEqual(CommandBlockText.output(""), "")
    }

    func testInputArrowsStayAvailableForHistoryIncludingWhenPredictionIsVisible() {
        XCTAssertEqual(action(PromptEvent.upArrow), .terminal)
        XCTAssertEqual(action(PromptEvent.downArrow), .terminal)
        XCTAssertEqual(action(PromptEvent.upArrow, mods: .command), .previous)
    }

    func testDraftKeepsHistoryAndMultilineArrowEditing() {
        for draft in ["ls", "echo one\necho two", " ", "日本語"] {
            XCTAssertEqual(action(PromptEvent.upArrow, draft: draft), .terminal)
            XCTAssertEqual(action(PromptEvent.downArrow, draft: draft), .terminal)
            XCTAssertEqual(action(PromptEvent.upArrow, mods: .command, draft: draft), .previous)
        }
    }

    func testBlockNavigationDoesNotReachShell() {
        XCTAssertEqual(action(PromptEvent.upArrow, browsing: true), .previous)
        XCTAssertEqual(action(PromptEvent.downArrow, browsing: true), .next)
        XCTAssertEqual(action(PromptEvent.escape, browsing: true), .input)
        XCTAssertEqual(action(PromptEvent.downArrow, mods: .command, browsing: true), .input)
        XCTAssertEqual(action(PromptEvent.returnKey, browsing: true), .reuse)
        XCTAssertEqual(action(PromptEvent.keypadEnter, browsing: true), .reuse)
        XCTAssertEqual(action(PromptEvent.tab, browsing: true), .actions)
        XCTAssertEqual(action(0, browsing: true), .typeInInput)
    }

    func testModifiedArrowsAndControlHistoryRemainShellKeys() {
        for mods: NSEvent.ModifierFlags in [.shift, .option, .control, [.command, .shift]] {
            XCTAssertEqual(action(PromptEvent.upArrow, mods: mods), .terminal)
        }
        XCTAssertEqual(action(35, mods: .control), .terminal) // Control-P
        XCTAssertEqual(action(45, mods: .control), .terminal) // Control-N
    }

    func testFullscreenAndRunningCommandsOwnAllKeys() {
        for key in [PromptEvent.upArrow, PromptEvent.downArrow, PromptEvent.returnKey,
                    PromptEvent.escape, PromptEvent.tab] {
            for browsing in [false, true] {
                XCTAssertEqual(action(key, ready: false, browsing: browsing), .terminal)
                XCTAssertEqual(action(key, mods: .command, ready: false, browsing: browsing), .terminal)
            }
        }
    }

    private func action(_ key: UInt16, mods: NSEvent.ModifierFlags = [], ready: Bool = true,
                        draft: String = "", browsing: Bool = false) -> CommandBlockInput.Action {
        CommandBlockInput.action(keyCode: key, modifiers: mods, promptReady: ready,
                                 draft: draft, browsing: browsing)
    }
}
