import XCTest

final class SoraZshBootstrapTests: XCTestCase {
    func testInstallsDotZshenvFromSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-zsh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("zshenv")
        try "# sora\n".write(to: source, atomically: true, encoding: .utf8)
        try "# highlight\n".write(
            to: root.appendingPathComponent("highlight.zsh"),
            atomically: true,
            encoding: .utf8
        )
        try "# blocks\n".write(
            to: root.appendingPathComponent("command-blocks.zsh"),
            atomically: true,
            encoding: .utf8
        )
        let zdot = root.appendingPathComponent("zdot", isDirectory: true)
        let installed = try SoraZshBootstrap.install(into: zdot, source: source)
        let dest = installed.appendingPathComponent(".zshenv")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "# sora\n")
        XCTAssertEqual(
            try String(
                contentsOf: installed.appendingPathComponent("highlight.zsh"),
                encoding: .utf8
            ),
            "# highlight\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: installed.appendingPathComponent("command-blocks.zsh"),
                encoding: .utf8
            ),
            "# blocks\n"
        )

        try "# sora-2\n".write(to: source, atomically: true, encoding: .utf8)
        _ = try SoraZshBootstrap.install(into: zdot, source: source)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "# sora-2\n")
    }
}

final class SoraShellIntegrationTests: XCTestCase {
    func testExportIsCompletePrivateAndDoesNotOverwrite() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("sora-shell-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sora/Resources")
        let installed = root.appendingPathComponent("installed")
        try SoraShellIntegration.install(into: installed, source: resources.appendingPathComponent("shell-integration"), zsh: resources.appendingPathComponent("zsh"))
        let ghostty = root.appendingPathComponent("fixture-ghostty")
        for name in SoraShellIntegration.ghosttyFiles {
            let file = ghostty.appendingPathComponent(name)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "unmodified fixture: \(name)".write(to: file, atomically: true, encoding: .utf8)
        }
        let destination = root.appendingPathComponent("export")
        try SoraShellIntegration.export(to: destination, installed: installed, ghostty: ghostty)
        for name in SoraShellIntegration.adapterFiles {
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(name)), try Data(contentsOf: destination.appendingPathComponent(name)))
        }
        for name in SoraShellIntegration.ghosttyFiles {
            let file = destination.appendingPathComponent("ghostty/" + name)
            XCTAssertEqual(try String(contentsOf: file), "unmodified fixture: \(name)")
            XCTAssertEqual((try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertThrowsError(try SoraShellIntegration.export(to: destination, installed: installed, ghostty: ghostty))
        XCTAssertTrue(manager.fileExists(atPath: destination.appendingPathComponent("README.txt").path))
        let missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try SoraShellIntegration.export(to: missing, installed: installed, ghostty: root.appendingPathComponent("absent")))
        XCTAssertFalse(manager.fileExists(atPath: missing.path))
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".sora-shell-") })
    }

    func testActivationQuotesPathsAsLiteralShellData() {
        let command = SoraShellIntegration.activationCommand(shell: "bash", directory: URL(fileURLWithPath: "/tmp/a b'$(bad)"))
        XCTAssertEqual(command, "source '/tmp/a b'\\''$(bad)/sora.bash'")
    }

    func testBashAdapterPreservesUnicodeTransport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Sora/Resources/shell-integration/sora.bash")
        let source = try String(contentsOf: script)
        // Extract the adapter's data-only functions; no interactive hooks are
        // installed in this subprocess. The actual shell path is verified natively.
        let functions = try XCTUnwrap(source.range(of: "_sora_bash_encode() {"))
        let end = try XCTUnwrap(source.range(of: "\nif (( BASH_VERSINFO", range: functions.upperBound..<source.endIndex))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sora-bash-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try String(source[functions.lowerBound..<end.lowerBound]).write(to: file, atomically: true, encoding: .utf8)
        let command = "printf '日本語\n%3B;😀 $(literal)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "source \"$1\"; _sora_bash_encode \"$2\"; _sora_bash_title \"sora-command;1;$_sora_encoded\"", "test", file.path, command]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        var assembler = ShellTitleAssembler()
        let reports = output.components(separatedBy: "\u{1b}]2;").dropFirst().compactMap {
            assembler.consume(String($0.dropLast())).flatMap(ShellEditLine.startedCommand)
        }
        XCTAssertEqual(reports, [command])
    }
}
