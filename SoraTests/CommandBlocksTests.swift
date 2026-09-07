import XCTest

final class CommandBlocksTests: XCTestCase {
    func testZshenvSourcesCommandBlocks() throws {
        let zshenv = resourceRoot().appendingPathComponent("Sora/Resources/zsh/zshenv")
        let source = try String(contentsOf: zshenv, encoding: .utf8)
        XCTAssertTrue(source.contains("command-blocks.zsh"))
        XCTAssertTrue(source.contains("PS1=''"))
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

    func testPrecmdPrintsDurationAndOneSpacingRowWithoutTerminalWidthRule() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            COLUMNS=40
            _sora_block_preexec
            _sora_block_start=$(( EPOCHREALTIME - 0.02 ))
            true
            _sora_block_precmd
            """,
            argument: script.path
        )
        let plain = stripANSI(output)
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3, plain)
        XCTAssertFalse(lines[0].isEmpty, plain)
        XCTAssertTrue(lines[1].isEmpty, plain)
        XCTAssertTrue(lines[2].isEmpty, plain)
        XCTAssertFalse(plain.contains("─"), plain)
        XCTAssertTrue(plain.hasPrefix("(") && plain.contains(")"), plain)
        XCTAssertTrue(plain.contains("ms") || plain.contains("s"), plain)
        XCTAssertFalse(output.contains("SORA_SEP"), output)
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
        XCTAssertFalse(plain.contains("─"), plain)
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
        XCTAssertTrue(stripANSI(output).contains("(agent)"), output)
        XCTAssertFalse(output.contains("SORA_SEP"), output)
        XCTAssertFalse(stripANSI(output).contains("─"), output)
    }

    func testAgentFlagMakesPrecmdDrawTheAgentRuleWithoutTiming() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let output = try runZsh(
            """
            source "$1"
            COLUMNS=48
            _sora_block_agent=1
            _sora_block_precmd
            _sora_block_precmd
            """,
            argument: script.path
        )
        let plain = stripANSI(output)
        XCTAssertTrue(plain.contains("(agent)"), plain)
        XCTAssertFalse(plain.contains("ms)"), plain)
        XCTAssertEqual(
            plain.split(separator: "\n", omittingEmptySubsequences: false).count,
            3,
            plain
        )
    }

    func testHandoffWidgetIsBoundToTheKeySoraSends() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let source = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(source.contains("bindkey -- \"$_SORA_AGENT_HANDOFF_KEY\" _sora_agent_handoff"), source)
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

    func testEmptyPrimaryReturnDoesNotAcceptButOtherInputDoes() throws {
        let script = resourceRoot().appendingPathComponent("Sora/Resources/zsh/command-blocks.zsh")
        let result = try runZsh(
            """
            source "$1"
            zle() { print -r -- "accepted:$BUFFER"; }
            CONTEXT=start BUFFER=''
            _sora_accept_line
            BUFFER='pwd'
            _sora_accept_line
            BUFFER=' '
            _sora_accept_line
            CONTEXT=cont BUFFER=''
            _sora_accept_line
            """,
            argument: script.path
        )
        XCTAssertEqual(result, "accepted:pwd\naccepted: \naccepted:\n")
    }

    private func stripANSI(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\u{1B}\\][^\u{07}]*\u{07}",
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
