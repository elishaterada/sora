import XCTest

final class ShellEditLineTests: XCTestCase {
    func testChunkedLongMultilineReport() {
        let text = String(repeating: "export DEMO='😀value'\n", count: 500)
        let report = ShellEditLine.multilineSentinel + "0;1;" + text.replacingOccurrences(of: "\n", with: "%0A")
        let scalars = Array(report.unicodeScalars)
        let chunks = stride(from: 0, to: scalars.count, by: 40).map {
            String(String.UnicodeScalarView(scalars[$0..<min($0 + 40, scalars.count)]))
        }
        var assembler = ShellTitleAssembler()
        for (index, chunk) in chunks.enumerated() {
            let title = "sora-chunk;\(index);\(chunks.count);\(chunk)"
            XCTAssertLessThan(title.utf8.count, 256)
            let result = assembler.consume(title)
            if index == chunks.count - 1 {
                XCTAssertEqual(result.flatMap { ShellEditLine.parse(title: $0) }, text)
            } else {
                XCTAssertNil(result)
            }
        }
    }

    func testIncompleteChunksNeverBecomeInputAndNextReportRecovers() {
        var assembler = ShellTitleAssembler()
        XCTAssertNil(assembler.consume("sora-chunk;0;3;first"))
        XCTAssertNil(assembler.consume("sora-chunk;2;3;missing"))
        XCTAssertEqual(assembler.consume("sora-chunk;0;1;fresh"), "fresh")
        XCTAssertEqual(assembler.consume("ordinary title"), "ordinary title")
    }

    func testStartedCommandTransportPreservesMultilineTextAndLiteralEscapes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let command = "printf '日本語\n\tline two\n%0A %09 %25\r\u{1b}\u{07}'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, value in value }
        process.arguments = ["-f", "-c", "source \"$1\"; _sora_report_command_started \"$2\"", "test",
                             root.appendingPathComponent("Sora/Resources/zsh/prompt-line.zsh").path, command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(output.hasPrefix("\u{1b}]2;"))
        XCTAssertTrue(output.hasSuffix("\u{07}"))
        var assembler = ShellTitleAssembler()
        let titles = output.components(separatedBy: "\u{1b}]2;").dropFirst().compactMap {
            assembler.consume(String($0.dropLast()))
        }
        let title = try XCTUnwrap(titles.last)
        XCTAssertEqual(ShellEditLine.startedCommand(title: title), command)
        XCTAssertNil(ShellEditLine.parse(title: title))
        XCTAssertFalse(ShellEditLine.isMirror(title: title))
        XCTAssertEqual(ShellEditLine.startedCommand(title: ShellEditLine.commandStartedTitle), "")
        XCTAssertNil(ShellEditLine.startedCommand(title: "ordinary title"))
    }

    func testNewEmptyPromptPublishesAfterCancellationWithoutRedraw() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, value in value }
        process.arguments = ["-f", "-c", "source \"$1\"; BUFFER='' CURSOR=0 _SORA_RESTORE_DRAFT=''; _sora_begin_line",
                             "test", root.appendingPathComponent("Sora/Resources/zsh/prompt-line.zsh").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\u{1b}]2;" + ShellEditLine.multilineSentinel + "0;0;\u{07}")
    }

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

final class ShellContextReportTests: XCTestCase {
    func testRemoteContextNeverBecomesLocalFromClientCWD() throws {
        let local = try XCTUnwrap(ShellContextReport.parse("sora-context;1;zsh;local;mac;/Users/me/project"))
        let remote = try XCTUnwrap(ShellContextReport.parse("sora-context;1;bash;remote;server;/srv/a%3Bb%25c/日本語"))
        XCTAssertEqual(remote.path, "/srv/a;b%c/日本語")
        XCTAssertTrue(ShellContextReport.isRemote(report: local, foreground: "ssh"))
        XCTAssertTrue(ShellContextReport.isRemote(report: nil, foreground: "mosh-client"))
        XCTAssertTrue(ShellContextReport.isRemote(report: remote, foreground: "sh"))
        XCTAssertFalse(ShellContextReport.isRemote(report: local, foreground: "zsh"))
        XCTAssertFalse(ShellContextReport.isRemote(report: remote, foreground: "bash", reportedPID: 20, foregroundPID: 10))
        XCTAssertTrue(ShellContextReport.isRemote(report: remote, foreground: "sh", reportedPID: 20, foregroundPID: 20))
        XCTAssertEqual(ShellContextReport.displayRemote(report: remote), "server:/srv/a;b%c/日本語")
        XCTAssertEqual(ShellContextReport.displayRemote(report: local), "Remote terminal")
    }

    func testRejectsMalformedOrUnsafeContextWithoutInterpretingIt() {
        for value in ["sora-context;2;zsh;local;mac;/tmp", "sora-context;1;fish;local;mac;/tmp",
                      "sora-context;1;zsh;unknown;mac;/tmp", "sora-context;1;zsh;remote;;/tmp",
                      "sora-context;1;zsh;remote;host;relative", "sora-context;1;zsh;remote;host;/tmp/%00",
                      "sora-context;1;zsh;remote;host;/tmp/%GG", "sora-context;1;zsh;remote;host;/tmp/%1B"] {
            XCTAssertNil(ShellContextReport.parse(value), value)
        }
    }

    func testZshContextReportEncodesRemoteHostAndLiteralPaths() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = ProcessInfo.processInfo.environment.merging(["SSH_CONNECTION": "fixture", "HOST": "fixture-host", "LC_ALL": "en_US.UTF-8"]) { _, value in value }
        process.arguments = ["-f", "-c", "source \"$1\"; PWD='/srv/日本語;a%25'; _sora_report_context", "test",
                             root.appendingPathComponent("Sora/Resources/zsh/prompt-line.zsh").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        var assembler = ShellTitleAssembler()
        let reports = output.components(separatedBy: "\u{1b}]2;").dropFirst().compactMap {
            assembler.consume(String($0.dropLast())).flatMap(ShellContextReport.parse)
        }
        let report = try XCTUnwrap(reports.last)
        XCTAssertTrue(report.isRemote)
        XCTAssertEqual(report.path, "/srv/日本語;a%25")
    }
}
