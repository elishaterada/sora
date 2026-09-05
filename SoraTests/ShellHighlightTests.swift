import XCTest

final class ShellHighlightTests: XCTestCase {
    func testColorsCommandFlagsAndPaths() throws {
        let highlights = try highlight("ls -la ~/Downloads")
        XCTAssertTrue(highlights.contains { $0.contains("fg=green") })
        XCTAssertTrue(highlights.contains { $0.contains("fg=magenta") })
        XCTAssertTrue(highlights.contains { $0.contains("fg=cyan") })
    }

    func testUnknownCommandIsRed() throws {
        let highlights = try highlight("notacommandxyz --flag")
        XCTAssertTrue(highlights.contains { $0.hasPrefix("0 ") && $0.contains("fg=red") })
        XCTAssertTrue(highlights.contains { $0.contains("fg=magenta") })
    }

    func testQuotedArgumentIsYellow() throws {
        let highlights = try highlight("echo 'hello'")
        XCTAssertTrue(highlights.contains { $0.contains("fg=yellow") })
    }

    func testPipelineResetsCommandPosition() throws {
        let highlights = try highlight("echo hi | wc")
        let greens = highlights.filter { $0.contains("fg=green") }
        XCTAssertGreaterThanOrEqual(greens.count, 2)
    }

    func testDisablesPasteStandoutThatPaintsSpacesAsBlocks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("Sora/Resources/zsh/highlight.zsh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f", "-c",
            "source \"$1\"; print -r -- ${zle_highlight[(r)paste:*]}",
            "sora-highlight",
            script.path
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(output, "paste:none")
    }

    private func highlight(_ buffer: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("Sora/Resources/zsh/highlight.zsh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f", "-c",
            "source \"$1\"; BUFFER=\"$2\"; typeset -ga region_highlight; _sora_highlight_apply; print -l -- $region_highlight",
            "sora-highlight",
            script.path,
            buffer
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }
}
