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

    func testPrecmdPrintsRuleAndDurationAfterArmedCommand() throws {
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
        XCTAssertTrue(output.contains("─"), output)
        XCTAssertTrue(output.contains("ms)") || output.contains("s)"), output)
        XCTAssertFalse(output.contains("exit"), output)
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
        XCTAssertTrue(output.contains("exit 1"), output)
        XCTAssertTrue(output.contains("─"), output)
    }

    func testAgentHandoffClosesTheBlockWithItsOwnLabel() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            COLUMNS=40
            _sora_block_rule ' (agent)'
            """,
            argument: script.path
        )
        XCTAssertTrue(output.contains("─"), output)
        XCTAssertTrue(output.contains("(agent)"), output)
        // The rule plus label fills the terminal width, ignoring color escapes.
        let plain = output
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(plain.count, 40, plain)
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
        XCTAssertTrue(output.contains("(agent)"), output)
        XCTAssertFalse(output.contains("ms)"), output)
        XCTAssertEqual(output.split(separator: "\n").count, 1, output)
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
