import XCTest

final class OutputSearchTests: XCTestCase {
    func testLiteralUnicodeMatchesAndNavigationUseTextViewRanges() {
        let source = "café 🚀\nliteral [x] café\nCAFE\n"
        let result = OutputSearchText.search(source, query: "café", matchingLinesOnly: false)
        XCTAssertEqual(result.matches.count, 2)
        for range in result.matches { XCTAssertEqual((source as NSString).substring(with: range), "café") }
        XCTAssertEqual(result.next(from: nil, previous: false), 0)
        XCTAssertEqual(result.next(from: 1, previous: false), 0)
        XCTAssertEqual(result.next(from: 0, previous: true), 1)
        XCTAssertEqual(OutputSearchText.search(source, query: "[x]", matchingLinesOnly: false).matches.count, 1)
        XCTAssertEqual(OutputSearchText.search(source, query: "🚀", matchingLinesOnly: false).matches.first?.length, 2)
        XCTAssertNil(OutputSearchText.search(source, query: "missing", matchingLinesOnly: false).next(from: nil, previous: false))
    }
    func testLineFilterIsReadOnlyAndResetRestoresAllOutput() {
        let source = "start\n  ERROR one\nkeep\nerror two\nend\n"
        let filtered = OutputSearchText.search(source, query: "error", matchingLinesOnly: true)
        XCTAssertEqual(filtered.text, "  ERROR one\nerror two")
        XCTAssertEqual(filtered.matchingLines, 2)
        XCTAssertEqual(filtered.matches.count, 2)
        XCTAssertEqual(OutputSearchText.search(source, query: "error", matchingLinesOnly: false).text, source)
        XCTAssertEqual(OutputSearchText.search(source, query: "", matchingLinesOnly: true).text, source)
        XCTAssertTrue(OutputSearchText.search(source, query: "no match", matchingLinesOnly: true).text.isEmpty)
    }
    func testLargeSnapshotsAndMatchListsHaveExplicitBounds() {
        let source = String(repeating: "x\n", count: 20_000)
        let full = OutputSearchText.search(source, query: "x", matchingLinesOnly: false)
        XCTAssertEqual(full.matches.count, OutputSearchText.matchLimit)
        XCTAssertTrue(full.hasMoreMatches)
        let filtered = OutputSearchText.search(source, query: "x", matchingLinesOnly: true)
        XCTAssertEqual(filtered.matchingLines, OutputSearchText.matchLimit)
        XCTAssertTrue(filtered.hasMoreLines)
        let snapshot = OutputSearchSnapshot(text: String(repeating: "é", count: 500_001), command: "large output")
        XCTAssertEqual(snapshot.text.utf8.count, 1_000_000)
        XCTAssertTrue(snapshot.isExcerpt)
        XCTAssertFalse(snapshot.text.contains("�"))
    }
    func testSearchWorkerDropsSupersededAndCancelledResults() {
        let worker = OutputSearchWorker()
        let finished = expectation(description: "only latest result applies")
        var received: [String] = []
        worker.onResult = { result in
            XCTAssertTrue(Thread.isMainThread)
            received.append(result.text)
            finished.fulfill()
        }
        worker.search(source: String(repeating: "old\n", count: 100_000), query: "old", filtered: true)
        worker.search(source: "superseded", query: "s", filtered: false)
        worker.cancel()
        worker.search(source: "latest", query: "a", filtered: false)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(received, ["latest"])
    }
}

final class CompletionEngineTests: XCTestCase {
    func testPrefersSameCwdHistoryOverFrequency() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let other = URL(fileURLWithPath: "/tmp/other")
        let now = Date(timeIntervalSince1970: 1_000)
        let suggestion = CompletionEngine.suggest(
            line: "gi",
            cwd: cwd,
            now: now,
            history: [
                HistoryCommandStat(
                    command: "git push",
                    lastCwd: other,
                    frequency: 20,
                    lastUsed: now,
                    sameCwdCount: 0
                ),
                HistoryCommandStat(
                    command: "git status",
                    lastCwd: cwd,
                    frequency: 2,
                    lastUsed: now.addingTimeInterval(-100),
                    sameCwdCount: 2
                ),
            ],
            pathMatches: []
        )
        XCTAssertEqual(suggestion?.insertSuffix, "t status")
        XCTAssertEqual(suggestion?.source, .history)
    }

    func testHistorySuffixKeepsLeadingSpaceBeforeNextToken() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let now = Date(timeIntervalSince1970: 1_000)
        let suggestion = CompletionEngine.suggest(
            line: "git",
            cwd: cwd,
            now: now,
            history: [
                HistoryCommandStat(
                    command: "git status",
                    lastCwd: cwd,
                    frequency: 3,
                    lastUsed: now,
                    sameCwdCount: 3
                ),
            ],
            pathMatches: []
        )
        XCTAssertEqual(suggestion?.insertSuffix, " status")
        XCTAssertTrue(suggestion?.insertSuffix.hasPrefix(" ") == true)
    }

    func testHistorySuffixKeepsLeadingSpaceBeforeFlags() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let now = Date(timeIntervalSince1970: 1_000)
        let suggestion = CompletionEngine.suggest(
            line: "ls",
            cwd: cwd,
            now: now,
            history: [
                HistoryCommandStat(
                    command: "ls -lah",
                    lastCwd: cwd,
                    frequency: 4,
                    lastUsed: now,
                    sameCwdCount: 4
                ),
            ],
            pathMatches: []
        )
        XCTAssertEqual(suggestion?.insertSuffix, " -lah")
        XCTAssertEqual(suggestion?.displayText, " -lah")
    }

    func testPathLikeTokenBeatsHistory() throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-complete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )

        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent("src/app", isDirectory: true),
            withIntermediateDirectories: true
        )

        let historyPrefix = CompletionEngine.suggest(
            line: "ls s",
            cwd: cwd,
            now: Date(),
            history: [
                HistoryCommandStat(
                    command: "ls src",
                    lastCwd: cwd,
                    frequency: 4,
                    lastUsed: Date(),
                    sameCwdCount: 4
                ),
            ],
            pathMatches: PathCompleter.matches(token: "s", cwd: cwd)
        )
        XCTAssertEqual(historyPrefix?.insertSuffix, "rc")
        XCTAssertEqual(historyPrefix?.source, .history)

        let cwdFilePrefix = CompletionEngine.suggest(
            line: "ls sr",
            cwd: cwd,
            now: Date(),
            history: [],
            pathMatches: PathCompleter.matches(token: "sr", cwd: cwd)
        )
        XCTAssertEqual(cwdFilePrefix?.insertSuffix, "c/")
        XCTAssertEqual(cwdFilePrefix?.source, .path)

        let pathFirst = CompletionEngine.suggest(
            line: "ls src/",
            cwd: cwd,
            now: Date(),
            history: [
                HistoryCommandStat(
                    command: "ls src/old",
                    lastCwd: cwd,
                    frequency: 4,
                    lastUsed: Date(),
                    sameCwdCount: 4
                ),
            ],
            pathMatches: PathCompleter.matches(token: "src/", cwd: cwd)
        )
        XCTAssertEqual(pathFirst?.insertSuffix, "app/")
        XCTAssertEqual(pathFirst?.source, .path)
    }

    func testRequiresTwoCharactersForHistory() {
        let cwd = URL(fileURLWithPath: "/tmp")
        let suggestion = CompletionEngine.suggest(
            line: "g",
            cwd: cwd,
            now: Date(),
            history: [
                HistoryCommandStat(
                    command: "git status",
                    lastCwd: cwd,
                    frequency: 1,
                    lastUsed: Date(),
                    sameCwdCount: 1
                ),
            ],
            pathMatches: []
        )
        XCTAssertNil(suggestion)
    }
}

final class CommandCompletionTests: XCTestCase {
    private func fixture() throws -> URL {
        // /tmp and /private/tmp expose macOS URL normalization differences.
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("sora-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func request(_ line: String, in root: URL) throws -> CommandCompletionRequest {
        try XCTUnwrap(CommandCompletionRequest.parse(line: line, directory: root))
    }

    func testSupportedContextsAndShellSyntaxFallback() throws {
        let root = try fixture()
        for line in ["gco feature", "g switch main", "git -C repo switch main", "git switch 'fea", "git switch fe\\ at", "npm run $(echo foo)", "ls foo | rg --", "git switch main\n", "git\tstatus"] {
            XCTAssertNil(CommandCompletionRequest.parse(line: line, directory: root), line)
        }
        XCTAssertEqual(try request("git s", in: root).kind, .gitCommands)
        XCTAssertEqual(try request("git  switch  ", in: root).head, "git  switch  ")
        XCTAssertEqual(try request("git rebase fe", in: root).kind, .branches)
        for manager in ["npm", "pnpm", "yarn", "bun"] {
            XCTAssertEqual(try request("\(manager) run dev", in: root).kind, .scripts)
        }
        let flag = try request("git log --max", in: root)
        let choice = try XCTUnwrap(CommandCompletionEngine.lookup(flag).first)
        XCTAssertEqual(choice.inserting(into: flag), "git log --max-count=")
        XCTAssertFalse(choice.detail.isEmpty)
    }

    func testBranchesCombineLoosePackedAndWorktreeCommonDirectory() throws {
        let root = try fixture()
        try write("ref: refs/heads/main\n", ".git/HEAD", in: root)
        try write("abc\n", ".git/refs/heads/feature/one", in: root)
        try write("abc refs/heads/main\nabc refs/heads/feature/one\nabc refs/tags/v1\n^abc\n", ".git/packed-refs", in: root)
        try write("gitdir: ../.git/worktrees/child\n", "child/.git", in: root)
        try write("../..\n", ".git/worktrees/child/commondir", in: root)
        let choices = try CommandCompletionEngine.lookup(request("git switch ", in: root.appendingPathComponent("child")))
        XCTAssertEqual(choices.map(\.value), ["feature/one", "main"])
        XCTAssertEqual(try CommandCompletionEngine.lookup(request("git switch fe", in: root)).map(\.value), ["feature/one"])
        // Files beneath a symlink are not branch names in this repository.
        try write("abc\n", "outside/unrelated", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git/refs/heads/linked"), withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertEqual(try CommandCompletionEngine.lookup(request("git switch ", in: root)).count, 2)
    }

    func testScriptsUseNearestPackageAndInsertLiteralNames() throws {
        let root = try fixture()
        try write("{\"scripts\":{\"outer\":\"false\"}}", "package.json", in: root)
        let name = "build 'é';$(touch marker)"
        let data = try JSONSerialization.data(withJSONObject: ["scripts": [name: "printf one\nprintf two", "-unsafe": "false", "dev": "start", "bad\nname": "false"]])
        try write(String(decoding: data, as: UTF8.self), "app/package.json", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        let request = try request("npm run ", in: root.appendingPathComponent("app/src"))
        let choices = try CommandCompletionEngine.lookup(request)
        XCTAssertEqual(choices.map(\.value), [name, "dev"])
        let choice = try XCTUnwrap(choices.first)
        XCTAssertEqual(choice.inserting(into: request), "npm run 'build '\\''é'\\'';$(touch marker)' ")
        XCTAssertEqual(choice.detail, "printf oneprintf two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    func testLargeAndInvalidDataIsBoundedOrReported() throws {
        let root = try fixture()
        try write((0..<20_000).map { "abc refs/heads/branch-\($0)\n" }.joined(), ".git/packed-refs", in: root)
        XCTAssertEqual(try CommandCompletionEngine.lookup(request("git switch ", in: root)).count, 80)
        XCTAssertEqual(try CommandCompletionEngine.lookup(request("git switch branch-19999", in: root)).first?.value, "branch-19999")
        try write(String(repeating: "x", count: 1_000_001), "package.json", in: root)
        XCTAssertThrowsError(try CommandCompletionEngine.lookup(request("npm run ", in: root)))
        try write("{broken", "package.json", in: root)
        XCTAssertThrowsError(try CommandCompletionEngine.lookup(request("npm run ", in: root)))
        try write(String(repeating: "x", count: 1_000_001), ".git/packed-refs", in: root)
        XCTAssertThrowsError(try CommandCompletionEngine.lookup(request("git switch ", in: root)))
    }

    func testMenuLookupCoalescesTypingAndCancelInvalidatesResults() throws {
        let root = try fixture()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "First lookup started")
        let last = expectation(description: "Latest lookup delivered")
        var lookedUp: [String] = [] // Only the serial lookup worker touches this until completion.
        let session = CommandCompletionSession { request in
            lookedUp.append(request.line)
            if lookedUp.count == 1 { started.fulfill(); gate.wait() }
            return [CommandCompletionChoice(value: request.prefix, detail: "Fixture")]
        }
        session.request(try request("git first", in: root)) { _ in XCTFail("Canceled request delivered") }
        wait(for: [started], timeout: 2)
        session.cancel()
        XCTAssertFalse(session.isPending)
        for n in 0..<1000 {
            session.request(try request("git obsolete\(n)", in: root)) { _ in XCTFail("Obsolete lookup delivered") }
        }
        session.request(try request("git latest", in: root)) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get().first?.value, "latest")
            XCTAssertEqual(lookedUp, ["git first", "git latest"])
            XCTAssertFalse(session.isPending)
            last.fulfill()
        }
        gate.signal()
        wait(for: [last], timeout: 5)
    }
}

extension CompletionEngineTests {
    func testPathSuggestionsEscapeShellCharactersAndDeferQuotedContexts() {
        let cwd = URL(fileURLWithPath: "/tmp")
        let suggestion = CompletionEngine.suggest(line: "ls pa", cwd: cwd, now: Date(), history: [],
            pathMatches: [.init(token: "path 'é';$(echo)/", isDirectory: true)])
        XCTAssertEqual(suggestion?.insertSuffix, "th\\ \\'é\\'\\;\\$\\(echo\\)/")
        for line in ["ls \"pa", "ls 'pa", "ls path\\ pa", "echo $(ls pa"] {
            XCTAssertNil(CompletionEngine.suggest(line: line, cwd: cwd, now: Date(), history: [],
                pathMatches: [.init(token: "path with spaces/", isDirectory: true)]))
        }
        XCTAssertNil(CompletionEngine.suggest(line: "ls pa", cwd: cwd, now: Date(), history: [],
            pathMatches: [.init(token: "path\ncommand", isDirectory: false)]))
    }
}

final class TerminalAppearanceTests: XCTestCase {
    func testAppearanceOverlayUsesInstalledFontsAndCannotInjectConfig() {
        XCTAssertTrue(TerminalPreferences.fontFamilies.contains("SF Mono"))
        XCTAssertEqual(TerminalPreferences.validatedFontFamily("unknown\ncommand = dangerous"), "SF Mono")
        let config = TerminalPreferences.ghosttyAppearanceConfig(light: false,
            family: "unknown\ncommand = dangerous", compact: true, size: 18)
        XCTAssertTrue(config.hasPrefix("font-family =\nfont-family = \"SF Mono\"\n"))
        XCTAssertFalse(config.contains("command ="))
        XCTAssertTrue(config.contains("window-padding-x = 16\n"))
        XCTAssertTrue(config.contains("adjust-cell-height = 4%\n"))
        XCTAssertFalse(config.contains("background =")) // Fresh bundled dark config owns its palette.
        let light = TerminalPreferences.ghosttyAppearanceConfig(light: true, family: "SF Mono", compact: false, size: 20)
        XCTAssertTrue(light.contains("font-size = 20.0\n"))
        XCTAssertTrue(light.contains("window-padding-x = 24\n"))
        XCTAssertEqual(light.components(separatedBy: "\n").filter { $0.hasPrefix("palette =") }.count, 16)
    }

    func testLightPaletteHasReadableForegroundAndAccent() throws {
        let config = TerminalPreferences.ghosttyAppearanceConfig(light: true, family: "SF Mono", compact: false, size: 18)
        let entries = Dictionary(uniqueKeysWithValues: config.split(separator: "\n").compactMap { line -> (String, UInt32)? in
            let fields = line.components(separatedBy: " = #")
            guard fields.count == 2, let hex = UInt32(fields[1], radix: 16) else { return nil }
            return (fields[0], hex)
        })
        func luminance(_ hex: UInt32) -> Double {
            let values = [16, 8, 0].map { shift -> Double in
                let s = Double((hex >> shift) & 255) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let background = luminance(try XCTUnwrap(entries["background"]))
        for key in ["foreground", "cursor-color"] {
            let foreground = luminance(try XCTUnwrap(entries[key]))
            XCTAssertGreaterThan((background + 0.05) / (foreground + 0.05), 4.5, key)
        }
        XCTAssertEqual(StickyPromptBarModel.visibleLineCount(total: 10, maximumHeight: 156, baseHeight: 96, lineHeight: 30), 3)
    }
}

final class AppShortcutTests: XCTestCase {
    func testControlCommandArrowsKeepNavigationIdentity() throws {
        for (code, key) in [(123, "\u{F702}"), (124, "\u{F703}"), (125, "\u{F701}"), (126, "\u{F700}")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .control, .numericPad, .function], timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(code)))
            XCTAssertEqual(AppKeyBinding(event: event), AppKeyBinding(key, [.command, .control]))
        }
    }
    private func fixture() -> UserDefaults {
        let suite = "sora-shortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    func testShortcutChangePersistsAndRejectsConflictsWithoutOverwriting() {
        let defaults = fixture()
        let store = AppShortcutStore(defaults: defaults)
        let custom = AppKeyBinding("p", [.command, .option])
        XCTAssertTrue(store.set(custom, for: .commandPalette))
        XCTAssertEqual(AppShortcutStore(defaults: defaults).binding(.commandPalette), custom)
        let saved = defaults.data(forKey: AppShortcutStore.defaultsKey)
        XCTAssertFalse(store.set(AppKeyBinding("t"), for: .commandPalette))
        XCTAssertTrue(store.errorMessage?.contains("New Tab") == true)
        XCTAssertEqual(defaults.data(forKey: AppShortcutStore.defaultsKey), saved)
        XCTAssertFalse(store.set(AppKeyBinding("c"), for: .commandPalette))
        XCTAssertFalse(store.set(AppKeyBinding("p", .option), for: .commandPalette))
        XCTAssertFalse(store.set(AppKeyBinding("\n", .command), for: .commandPalette))
        XCTAssertEqual(store.binding(.commandPalette), custom)
        store.reset(.commandPalette)
        XCTAssertEqual(AppShortcutStore(defaults: defaults).binding(.commandPalette), AppShortcutAction.commandPalette.defaultBinding)
        XCTAssertNil(store.errorMessage)
    }
    func testResetReportsAnOccupiedDefaultAndResetAllRecovers() {
        let store = AppShortcutStore(defaults: fixture())
        XCTAssertTrue(store.set(AppKeyBinding("p", [.command, .option]), for: .commandPalette))
        XCTAssertTrue(store.set(AppShortcutAction.commandPalette.defaultBinding, for: .openAgent))
        store.reset(.commandPalette)
        XCTAssertTrue(store.errorMessage?.contains("Open Agent") == true)
        store.resetAll()
        for action in AppShortcutAction.allCases { XCTAssertEqual(store.binding(action), action.defaultBinding) }
    }
    func testCorruptOrConflictingSavedShortcutsStayVisibleAndPreserveOriginalData() throws {
        let defaults = fixture()
        let conflicting = try JSONEncoder().encode(["commandPalette": AppKeyBinding("t")])
        defaults.set(conflicting, forKey: AppShortcutStore.defaultsKey)
        let store = AppShortcutStore(defaults: defaults)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.binding(.commandPalette), AppShortcutAction.commandPalette.defaultBinding)
        XCTAssertEqual(defaults.data(forKey: AppShortcutStore.defaultsKey), conflicting)
        defaults.set(Data("broken".utf8), forKey: AppShortcutStore.defaultsKey)
        XCTAssertNotNil(AppShortcutStore(defaults: defaults).errorMessage)
        XCTAssertEqual(AppKeyBinding("\u{F700}", [.command, .option]).display, "⌥⌘↑")
    }
}
