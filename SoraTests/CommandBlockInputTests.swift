import XCTest
import AppKit

final class CommandBlockInputTests: XCTestCase {
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
