import XCTest

final class WorkspaceSnapshotTests: XCTestCase {
    func testRestoredTabsKeepDistinctHistoryIdentities() throws {
        let model = WorkspaceModel(snapshot: .empty)
        _ = model.addTab(workingDirectory: nil)
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(model.snapshot()))
        let restored = WorkspaceModel(snapshot: snapshot)
        XCTAssertEqual(restored.tabs.map(\.id), model.tabs.map(\.id))
        XCTAssertNotEqual(restored.tabs[0].id, restored.tabs[1].id)
    }

    func testLegacySnapshotStillLoads() throws {
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"directories":["/tmp"],"selectedIndex":0}"#.utf8))
        XCTAssertNil(snapshot.sessionIDs)
        XCTAssertEqual(WorkspaceModel(snapshot: snapshot).tabs.count, 1)
    }

    func testHistoryArchivePreservesTextWithoutTerminalControls() throws {
        let id = UUID()
        let url = TerminalHistoryArchive.url(for: id)
        defer { try? FileManager.default.removeItem(at: url) }
        try TerminalHistoryArchive.save("hello\n$(touch should-not-run)\u{1b}test", for: id)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "hello\n$(touch should-not-run)est\u{1b}[0m")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHistoryPreservesColorsButDropsTerminalActions() {
        let input = "\u{1b}[31mred\u{1b}[38;2;10;20;30mrgb\u{1b}[0m\u{1b}]52;c;secret\u{7}\u{1b}[2Jend"
        XCTAssertEqual(TerminalHistoryArchive.sanitized(input), "\u{1b}[31mred\u{1b}[38;2;10;20;30mrgb\u{1b}[0mend\u{1b}[0m")
        XCTAssertEqual(TerminalHistoryArchive.sanitized("a\u{1b}]8;;https://example.com\u{1b}\\b"), "ab\u{1b}[0m")
    }

    func testShellDraftRestorationIsLiteralAndOneShot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = directory.appendingPathComponent("draft")
        let text = "echo 'quoted'\n$(echo do-not-execute)\n"
        try text.write(to: draft, atomically: true, encoding: .utf8)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sora/Resources/zsh/prompt-line.zsh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, new in new }
        process.arguments = ["-f", "-c", "source \"$1\"; _SORA_RESTORE_DRAFT=\"$2\"; BUFFER=''; _sora_restore_draft; print -rn -- \"$BUFFER\"; [[ -z \"$_SORA_RESTORE_DRAFT\" ]]", "test", source.path, draft.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), text)
    }

    func testEmptySnapshotAlwaysHasOneDirectory() {
        let snapshot = WorkspaceSnapshot(directories: [], selectedIndex: 4)
        XCTAssertEqual(snapshot.directories, [""])
        XCTAssertEqual(snapshot.selectedIndex, 0)
    }

    func testSelectedIndexIsClamped() {
        let snapshot = WorkspaceSnapshot(directories: ["/tmp", "/usr"], selectedIndex: 9)
        XCTAssertEqual(snapshot.selectedIndex, 1)
    }

    func testRoundTripJSON() throws {
        let original = WorkspaceSnapshot(directories: ["/tmp", ""], selectedIndex: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
