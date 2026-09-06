import XCTest

final class CommandBlocksTests: XCTestCase {
    func testZshenvSourcesCommandBlocks() throws {
        let zshenv = resourceRoot().appendingPathComponent("Sora/Resources/zsh/zshenv")
        let source = try String(contentsOf: zshenv, encoding: .utf8)
        XCTAssertTrue(source.contains("command-blocks.zsh"))
    }

    func testFormatsSubSecondAndMultiSecondDurations() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            print -r -- "$(_sora_format_duration 0.0004)"
            print -r -- "$(_sora_format_duration 0.014)"
            print -r -- "$(_sora_format_duration 1.25)"
            print -r -- "$(_sora_format_duration 12.4)"
            print -r -- "$(_sora_format_duration 75)"
            """,
            argument: script.path
        )
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["<1ms", "14ms", "1.25s", "12.4s", "1m15s"])
    }

    func testPrecmdPrintsStatsAboveFullWidthRule() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            COLUMNS=40
            _sora_block_preexec
            # Simulate ~20ms of work without sleeping flaky amounts.
            _sora_block_start=$(( EPOCHREALTIME - 0.02 ))
            true
            _sora_block_precmd
            """,
            argument: script.path
        )
        let plain = stripANSI(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = plain.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, plain)
        XCTAssertTrue(lines[0].hasPrefix("(") && lines[0].hasSuffix(")"), lines[0])
        XCTAssertTrue(lines[0].contains("ms") || lines[0].contains("s"), lines[0])
        XCTAssertFalse(lines[0].contains("exit"), lines[0])
        XCTAssertTrue(lines[1].allSatisfy { $0 == "─" }, lines[1])
        XCTAssertEqual(lines[1].count, 40, plain)
    }

    func testFailedCommandIncludesExitCode() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            COLUMNS=48
            _sora_block_preexec
            _sora_block_start=$(( EPOCHREALTIME - 0.05 ))
            false
            _sora_block_precmd
            """,
            argument: script.path
        )
        let plain = stripANSI(output)
        XCTAssertTrue(plain.contains("exit 1"), plain)
        XCTAssertTrue(plain.contains("─"), plain)
    }

    func testAgentHandoffClosesTheBlockWithItsOwnLabel() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            COLUMNS=40
            _sora_block_rule '(agent)'
            """,
            argument: script.path
        )
        let plain = stripANSI(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = plain.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "(agent)", plain)
        XCTAssertEqual(lines[1], String(repeating: "─", count: 40), plain)
    }

    func testAgentFlagMakesPrecmdDrawTheAgentRuleWithoutTiming() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            COLUMNS=48
            _sora_block_agent=1
            _sora_block_precmd
            # The flag is consumed, so the next prompt draws nothing.
            _sora_block_precmd
            """,
            argument: script.path
        )
        let plain = stripANSI(output)
        XCTAssertTrue(plain.contains("(agent)"), plain)
        XCTAssertFalse(plain.contains("ms)"), plain)
        XCTAssertEqual(
            plain.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").count,
            2,
            plain
        )
    }

    func testHandoffWidgetIsBoundToTheKeySoraSends() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let source = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(source.contains("bindkey -- \"$_SORA_AGENT_HANDOFF_KEY\" _sora_agent_handoff"), source)
        // The shell binding and the character Sora writes must not drift apart.
        let key = try runZsh(
            """
            source "$1"
            printf %s "$_SORA_AGENT_HANDOFF_KEY"
            """,
            argument: script.path
        )
        XCTAssertEqual(
            key.unicodeScalars.map(\.value),
            [ShellEditLine.agentHandoffControl.value]
        )
    }

    private func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }

    private func resourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runZsh(_ script: String, argument: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", script, "sora-blocks", argument]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, err)
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
