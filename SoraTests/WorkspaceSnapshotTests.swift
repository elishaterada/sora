import XCTest

final class WorkspaceSnapshotTests: XCTestCase {
    func testNestedPaneGeometryFocusAndRemovalKeepIndependentIdentities() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let tree = PaneLayout<UUID>.leaf(a).splitting(a, adding: b, axis: .right)
            .splitting(b, adding: c, axis: .below).splitting(a, adding: d, axis: .below)
        XCTAssertEqual(tree.leaves, [a, d, b, c])
        XCTAssertTrue(tree.isValid(allowed: [a, b, c, d]))
        let geometry = tree.geometry(in: CGRect(x: 13, y: 27, width: 1001, height: 701))
        XCTAssertEqual(geometry.dividers.count, 3)
        XCTAssertEqual(geometry.panes[a]?.width, 500)
        XCTAssertEqual(geometry.panes[a]?.height, 350)
        XCTAssertGreaterThan(geometry.panes[a]!.minY, geometry.panes[d]!.minY)
        XCTAssertEqual(tree.neighbor(of: a, direction: .right), b)
        XCTAssertEqual(tree.neighbor(of: a, direction: .down), d)
        XCTAssertEqual(tree.neighbor(of: c, direction: .up), b)
        XCTAssertEqual(tree.neighbor(of: c, direction: .left), d)
        XCTAssertNil(tree.neighbor(of: a, direction: .up))
        XCTAssertEqual(tree.focusAfterRemoving(c), b)
        XCTAssertEqual(tree.focusAfterRemoving(a), d)
        XCTAssertNil(PaneLayout<UUID>.leaf(a).focusAfterRemoving(a))
        for (id, rect) in geometry.panes {
            for (other, second) in geometry.panes where other != id { XCTAssertFalse(rect.intersects(second)) }
        }
        let reduced = try XCTUnwrap(tree.retaining([a, b, c]))
        XCTAssertEqual(reduced.leaves, [a, b, c])
        XCTAssertEqual(reduced.geometry(in: CGRect(x: 0, y: 0, width: 1001, height: 701)).panes[a]?.height, 701)
        XCTAssertEqual(tree.retaining([c]), .leaf(c))
        XCTAssertNil(tree.retaining([]))
    }

    func testPaneRatiosAndMaximizeSurviveWorkspaceEncoding() throws {
        let ids = [UUID(), UUID(), UUID()]
        var snapshot = WorkspaceSnapshot(directories: ["", "", ""], selectedIndex: 2, sessionIDs: ids)
        let tree = PaneLayout<UUID>.leaf(ids[0]).splitting(ids[0], adding: ids[1], axis: .below)
            .splitting(ids[1], adding: ids[2], axis: .right)
        let branch = try XCTUnwrap(tree.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 800)).dividers.first?.id)
        snapshot.paneLayout = tree.settingFraction(0.65, for: branch)
        snapshot.isPaneMaximized = true
        let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.restoredPaneLayout(), snapshot.paneLayout)
        XCTAssertEqual(restored.paneLayout?.leaves, ids)
        XCTAssertEqual(tree.settingFraction(.nan, for: branch), tree)
        XCTAssertEqual(tree.settingFraction(9, for: branch).geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 800)).dividers.first?.fraction, 0.8)
    }

    func testLegacySplitMigrationAndInvalidTreesAreProtected() throws {
        let ids = [UUID(), UUID()]
        var snapshot = WorkspaceSnapshot(directories: ["", ""], selectedIndex: 1, sessionIDs: ids)
        snapshot.splitIDs = ids; snapshot.splitFraction = 0.35
        let legacy = try XCTUnwrap(snapshot.restoredPaneLayout())
        XCTAssertEqual(legacy.leaves, ids)
        XCTAssertEqual(legacy.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 800)).dividers.first?.axis, .right)
        snapshot.paneLayout = .split(id: UUID(), axis: .below, fraction: 0.5, first: .leaf(ids[0]), second: .leaf(ids[0]))
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)))
        var oversized = PaneLayout<Int>.leaf(0)
        for index in 1...8 { oversized = oversized.splitting(index - 1, adding: index, axis: .right) }
        XCTAssertFalse(oversized.isValid(allowed: Set(0...8)))
        XCTAssertFalse(PaneLayout<UUID>.leaf(UUID()).isValid(allowed: Set(ids)))
    }

    func testRestoredTabsKeepDistinctHistoryIdentities() throws {
        let model = WorkspaceModel(snapshot: .empty)
        _ = model.addTab(workingDirectory: nil)
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(model.snapshot()))
        let restored = WorkspaceModel(snapshot: snapshot)
        XCTAssertEqual(restored.tabs.map(\.id), model.tabs.map(\.id))
        XCTAssertNotEqual(restored.tabs[0].id, restored.tabs[1].id)
    }

    func testColoredLogSanitizationScalesToLargeHistory() {
        let line = "\u{1b}[36mapi-1\u{1b}[0m | completed café 🚀\n"
        let text = String(repeating: line, count: 100_000)
        let start = Date()
        XCTAssertEqual(TerminalHistoryArchive.sanitized(text), text + "\u{1b}[0m")
        // Generous regression ceiling: the former repeated string copies take
        // seconds on this fixture, while linear processing takes milliseconds.
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testHistoryWriterCoalescesPendingSnapshotsAndFlushesLatest() {
        let started = expectation(description: "first write started")
        let release = DispatchSemaphore(value: 0)
        let latest = expectation(description: "latest snapshot persisted")
        let id = UUID()
        let writer = TerminalHistoryWriter { snapshot in
            XCTAssertFalse(Thread.isMainThread)
            if snapshot.draft == "first" {
                started.fulfill()
                release.wait()
            } else {
                XCTAssertEqual(snapshot.draft, "latest")
                latest.fulfill()
            }
        }
        writer.enqueue(.init(id: id, text: nil, draft: "first"))
        wait(for: [started], timeout: 5)
        writer.enqueue(.init(id: id, text: nil, draft: "superseded"))
        writer.enqueue(.init(id: id, text: nil, draft: "latest"))
        release.signal()
        writer.flush()
        wait(for: [latest], timeout: 1)
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

    func testHistoryRetainsOnlyPassiveArchiveBoundaries() {
        let markers = ["133;A;aid=sora-archive", "133;P;k=s;aid=sora-archive",
                       "133;B;aid=sora-archive", "133;C;aid=sora-archive"]
        for marker in markers {
            let canonical = "\u{1b}]\(marker)\u{1b}\\"
            for ending in ["\u{7}", "\u{1b}\\"] {
                XCTAssertEqual(TerminalHistoryArchive.sanitized("\u{1b}]\(marker)\(ending)echo café"),
                               canonical + "echo café\u{1b}[0m")
            }
        }
        for marker in ["133;C", "133;D;0;aid=sora-archive", "133;A;aid=sora-archive;cl=line",
                       "2;title", "52;c;clipboard", "133;A;aid=sora-archive-spoof"] {
            XCTAssertEqual(TerminalHistoryArchive.sanitized("before\u{1b}]\(marker)\u{7}after"),
                           "beforeafter\u{1b}[0m")
        }
        XCTAssertEqual(TerminalHistoryArchive.sanitized("\u{1b}P133;A;aid=sora-archive\u{1b}\\"), "\u{1b}[0m")
        XCTAssertEqual(TerminalHistoryArchive.sanitized("before\u{1b}]133;A;aid=sora-archive"), "before\u{1b}[0m")
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

    func testRestoreBannersDoNotAccumulate() {
        let marker = "── Previous session ended · New shell ──"
        let output = "command\nresult\n"
        let once = TerminalHistoryArchive.removingRestoreBanners(output + "\n" + marker + "\n")
        XCTAssertEqual(once, output)
        XCTAssertEqual(TerminalHistoryArchive.removingRestoreBanners(once + "\n" + marker + "\n"), output)
        XCTAssertEqual(TerminalHistoryArchive.removingRestoreBanners("\n" + marker + "\n\n" + marker + "\n"), "")
        XCTAssertEqual(TerminalHistoryArchive.removingRestoreBanners("echo " + marker), "echo " + marker)
        let styled = "\u{1b}[0m" + marker + "\u{1b}[32m\nresult"
        XCTAssertEqual(TerminalHistoryArchive.removingRestoreBanners(styled), "\u{1b}[0m\u{1b}[32m\nresult")
        let boundary = "\u{1b}]133;C;aid=sora-archive\u{1b}\\"
        XCTAssertEqual(TerminalHistoryArchive.removingRestoreBanners(boundary + styled),
                       boundary + "\u{1b}[0m\u{1b}[32m\nresult")
    }

    func testUnsubmittedDraftsDoNotAccumulateInOutputAcrossLaunches() {
        let a = "\u{1b}]133;A;aid=sora-archive\u{1b}\\"
        let b = "\u{1b}]133;B;aid=sora-archive\u{1b}\\"
        let c = "\u{1b}]133;C;aid=sora-archive\u{1b}\\"
        let completed = a + b + "printf result\n" + c + "result\n"
        let draft = a + b + "echo unfinished\n"
        XCTAssertEqual(TerminalHistoryArchive.removingUnsubmittedPrompts(completed + draft + draft), completed)
        XCTAssertEqual(TerminalHistoryArchive.removingUnsubmittedPrompts(completed + a), completed + a)
        XCTAssertEqual(TerminalHistoryArchive.removingUnsubmittedPrompts(completed), completed)
        XCTAssertEqual(TerminalHistoryArchive.removingUnsubmittedPrompts("legacy output"), "legacy output")
        XCTAssertEqual(TerminalHistoryArchive.removingUnsubmittedPrompts(draft), "")
        let export = completed + draft + c
        XCTAssertEqual(TerminalHistoryArchive.preparingGhosttyExport(export, promptReady: true), completed + c)
        // No-output running commands can look like edit buffers in the export.
        XCTAssertEqual(TerminalHistoryArchive.preparingGhosttyExport(export, promptReady: false), export)
        XCTAssertEqual(TerminalHistoryArchive.preparingGhosttyExport(completed + draft, promptReady: true), completed + draft)

    }

    func testEmptySnapshotAlwaysHasOneDirectory() {
        let snapshot = WorkspaceSnapshot(directories: [], selectedIndex: 4)
        XCTAssertEqual(snapshot.directories, [""])
        XCTAssertEqual(snapshot.selectedIndex, 0)
    }

    func testDecodedEmptyWorkspaceIsNormalizedBeforeCreatingTabs() throws {
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self,
            from: Data(#"{"directories":[],"selectedIndex":100}"#.utf8))
        XCTAssertEqual(snapshot, .empty)
        XCTAssertEqual(WorkspaceModel(snapshot: snapshot).tabs.count, 1)
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
