import XCTest

final class ShellEditLineTests: XCTestCase {
    func testShellEmitsDistinctCommandStartedSignal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, value in value }
        process.arguments = ["-f", "-c", "source \"$1\"; _sora_report_command_started", "test", root.appendingPathComponent("Sora/Resources/zsh/prompt-line.zsh").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\u{1b}]2;" + ShellEditLine.commandStartedTitle + "\u{07}")
        XCTAssertNil(ShellEditLine.parse(title: ShellEditLine.commandStartedTitle))
        XCTAssertFalse(ShellEditLine.isMirror(title: ShellEditLine.commandStartedTitle))
    }

    func testMultilineTransportPreservesLiteralEscapesAndCursor() {
        let title = ShellEditLine.multilineSentinel + "8;1;echo a%0Aecho %250A"
        XCTAssertEqual(ShellEditLine.parse(title: title), "echo a\necho %0A")
        XCTAssertEqual(ShellEditLine.cursorOffset(title: title), 8)
        XCTAssertTrue(ShellEditLine.shellRecognizesCommand(title: title))
    }

    func testLiveShellCommandRecognitionReport() {
        let title = ShellEditLine.inputSentinel + "2;1;.."
        XCTAssertEqual(ShellEditLine.parse(title: title), "..")
        XCTAssertEqual(ShellEditLine.cursorOffset(title: title), 2)
        XCTAssertTrue(ShellEditLine.shellRecognizesCommand(title: title))
        XCTAssertTrue(ShellEditLine.isMirror(title: title))
        XCTAssertFalse(ShellEditLine.shellRecognizesCommand(title: ShellEditLine.inputSentinel + "2;0;hi"))
    }

    func testCursorReportsPreserveSemicolonsAndUnicode() {
        let title = ShellEditLine.cursorSentinel + "3;a😀b; echo hi"
        XCTAssertEqual(ShellEditLine.parse(title: title), "a😀b; echo hi")
        XCTAssertEqual(ShellEditLine.cursorOffset(title: title), 3)
        XCTAssertEqual(ShellEditLine.textBeforeCursor("a😀b; echo hi", scalarOffset: 2), "a😀")
        XCTAssertTrue(ShellEditLine.isMirror(title: title))
    }

    func testCursorReportValidationAndBounds() {
        for value in ["-1;text", "bad;text", "2"] {
            let title = ShellEditLine.cursorSentinel + value
            XCTAssertNil(ShellEditLine.parse(title: title))
            XCTAssertNil(ShellEditLine.cursorOffset(title: title))
        }
        XCTAssertEqual(ShellEditLine.parse(title: ShellEditLine.cursorSentinel + "0;"), "")
        XCTAssertEqual(ShellEditLine.textBeforeCursor("hello", scalarOffset: 99), "hello")
        XCTAssertEqual(ShellEditLine.textBeforeCursor("hello", scalarOffset: -1), "")
        XCTAssertEqual(ShellEditLine.textBeforeCursor("e\u{301}x", scalarOffset: 2), "e\u{301}")
    }

    private func mirror(_ line: String) -> String {
        ShellEditLine.sentinel + line
    }

    func testParsesMirroredBufferIncludingURLsWithQueryStrings() {
        let line = "Help me download youtube video https://www.youtube.com/watch?v=bOC3DisEOfg as mp4 into ~/Downloads"
        XCTAssertEqual(ShellEditLine.parse(title: mirror(line)), line)
        XCTAssertEqual(PromptIntentClassifier.submission(for: line), .agent(line))
    }

    func testEmptyBufferParsesAsEmptyNotNil() {
        XCTAssertEqual(ShellEditLine.parse(title: mirror("")), "")
        XCTAssertEqual(PromptIntentClassifier.submission(for: ""), .shell)
    }

    func testOrdinaryTitlesAreNotMirrors() {
        for title in ["sora", "git status", "~/repos/sora", ""] {
            XCTAssertNil(ShellEditLine.parse(title: title), title)
            XCTAssertFalse(ShellEditLine.isMirror(title: title), title)
        }
    }

    func testMirroredLineIsNotPollutedByPreviousScreenText() {
        // Regression: scraping the grid glued the previous (cancelled) line onto
        // the current one, producing "/agent " prefixes the user never typed.
        let previous = "/agent Help me download youtube video"
        let current = "Can you show me the largest files in this folder"
        XCTAssertEqual(ShellEditLine.parse(title: mirror(current)), current)
        XCTAssertNotEqual(ShellEditLine.parse(title: mirror(current)), previous + current)
    }

    func testMirroredCommandsStillRouteToShell() {
        for line in ["ls -la", "git status", "cd ~/repos/sora"] {
            let parsed = ShellEditLine.parse(title: mirror(line))
            XCTAssertEqual(parsed, line)
            XCTAssertEqual(PromptIntentClassifier.submission(for: parsed!), .shell, line)
        }
    }
}
