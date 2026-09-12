import XCTest

final class WorkspaceRestoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("windows.json") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testWindowCatalogMigratesLegacyWithoutLosingTabIDs() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let snapshot = WorkspaceSnapshot(directories: ["/tmp"], selectedIndex: 0, sessionIDs: [id], tabNames: ["Build"])
        WorkspaceRestore.save(snapshot, to: defaults)
        let store = WorkspaceWindowStore(defaults: defaults, url: url)
        XCTAssertEqual(store.windows.count, 1)
        XCTAssertEqual(store.windows[0].snapshot, snapshot)
        store.save(snapshot, for: store.windows[0].id)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).windows, store.windows)
    }

    func testWindowUpdatesAndCloseDoNotOverwriteOtherWindows() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceWindowStore(defaults: defaults, url: url)
        let first = store.windows[0].id
        let second = UUID()
        var a = WorkspaceSnapshot(directories: ["/tmp", "/usr"], selectedIndex: 1, sessionIDs: [UUID(), UUID()])
        a.splitIDs = a.sessionIDs
        a.windowFrame = "{{10, 20}, {900, 600}}"
        let b = WorkspaceSnapshot(directories: ["/var"], selectedIndex: 0, sessionIDs: [UUID()])
        store.save(a, for: first)
        store.save(b, for: second)
        let loaded = WorkspaceWindowStore(defaults: defaults, url: url)
        XCTAssertEqual(loaded.snapshot(for: first), a)
        XCTAssertEqual(loaded.snapshot(for: second), b)
        loaded.close(second, explicitlyRequested: true)
        XCTAssertEqual(loaded.windows.map(\.id), [first])
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).snapshot(for: first), a)
        loaded.isTerminating = true
        loaded.close(first, explicitlyRequested: true)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).windows.count, 1)
    }

    func testClosingLastWindowDoesNotResurrectLegacyTabs() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        WorkspaceRestore.save(WorkspaceSnapshot(directories: ["/old"], selectedIndex: 0), to: defaults)
        let store = WorkspaceWindowStore(defaults: defaults, url: url)
        store.close(store.windows[0].id, explicitlyRequested: true)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).windows[0].snapshot, .empty)
    }

    func testStaleProcessCannotDiscardAnotherProcessesNewTabs() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = WorkspaceWindowStore(defaults: defaults, url: url)
        let id = first.windows[0].id
        first.save(.empty, for: id)
        let stale = WorkspaceWindowStore(defaults: defaults, url: url)
        let changed = WorkspaceSnapshot(directories: ["/tmp", "/usr"], selectedIndex: 1,
                                        sessionIDs: [UUID(), UUID()], tabNames: ["Build", "Logs"])
        first.save(changed, for: id)
        stale.save(.empty, for: id)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).snapshot(for: id), changed)
    }

    func testMigrationSurvivesPreferencesResetAndRepeatedRelaunches() throws {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let ids = [UUID(), UUID()]
        var snapshot = WorkspaceSnapshot(directories: ["/missing/folder", "/tmp"], selectedIndex: 1,
                                         sessionIDs: ids, tabNames: ["Work", "Logs"])
        snapshot.splitIDs = ids
        snapshot.splitFraction = 0.65
        snapshot.windowFrame = "{{10, 20}, {900, 600}}"
        let record = WorkspaceWindowRecord(id: UUID(), snapshot: snapshot)
        let old = try JSONEncoder().encode([record])
        defaults.set(old, forKey: WorkspaceWindowStore.defaultsKey)
        let migrated = WorkspaceWindowStore(defaults: defaults, url: url)
        XCTAssertEqual(migrated.windows, [record])
        XCTAssertEqual(defaults.data(forKey: WorkspaceWindowStore.defaultsKey), old)
        defaults.removePersistentDomain(forName: name)
        for _ in 0..<3 {
            let launched = WorkspaceWindowStore(defaults: defaults, url: url)
            XCTAssertEqual(launched.windows, [record])
            XCTAssertTrue(launched.save(snapshot, for: record.id))
            launched.isTerminating = true
            launched.close(record.id, explicitlyRequested: true)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testIndependentProcessesMergeWindowsAndCannotResurrectClosedWindows() {
        let defaults = UserDefaults(suiteName: "dev.sora.tests.\(UUID().uuidString)")!
        let first = WorkspaceWindowStore(defaults: defaults, url: url)
        let id = first.windows[0].id
        XCTAssertTrue(first.save(.empty, for: id))
        let second = WorkspaceWindowStore(defaults: defaults, url: url)
        let other = UUID()
        let snapshot = WorkspaceSnapshot(directories: ["/tmp"], selectedIndex: 0)
        XCTAssertTrue(second.save(snapshot, for: other))
        first.close(id, explicitlyRequested: true)
        XCTAssertFalse(second.save(.empty, for: id))
        XCTAssertNotNil(second.persistenceError)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).windows.map(\.id), [other])
    }

    func testCorruptPrimaryRecoversBackupAndPreservesOriginalBytes() throws {
        let defaults = UserDefaults(suiteName: "dev.sora.tests.\(UUID().uuidString)")!
        let store = WorkspaceWindowStore(defaults: defaults, url: url)
        let id = store.windows[0].id
        let saved = WorkspaceSnapshot(directories: ["/tmp", "/usr"], selectedIndex: 1, sessionIDs: [UUID(), UUID()])
        XCTAssertTrue(store.save(saved, for: id))
        XCTAssertTrue(store.save(.empty, for: id))
        let broken = Data("interrupted write".utf8)
        try broken.write(to: url)
        let restored = WorkspaceWindowStore(defaults: defaults, url: url)
        XCTAssertNil(restored.persistenceError)
        XCTAssertEqual(restored.snapshot(for: id), saved)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("unreadable-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved)), broken)
        XCTAssertTrue(restored.save(saved, for: id))
    }

    func testUnreadableAndNewerCatalogsAreNeverOverwrittenByEmptyLaunch() throws {
        let defaults = UserDefaults(suiteName: "dev.sora.tests.\(UUID().uuidString)")!
        for text in ["broken", #"{"version":999,"entries":[]}"#] {
            let original = Data(text.utf8)
            try original.write(to: url)
            let store = WorkspaceWindowStore(defaults: defaults, url: url)
            XCTAssertNotNil(store.persistenceError)
            XCTAssertFalse(store.save(.empty, for: store.windows[0].id))
            store.close(store.windows[0].id, explicitlyRequested: true)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testInvalidLegacyPreferencesStayIntactAndDoNotCreateEmptyCatalog() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let original = Data("unreadable".utf8)
        defaults.set(original, forKey: WorkspaceWindowStore.defaultsKey)
        let store = WorkspaceWindowStore(defaults: defaults, url: url)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(store.save(.empty, for: store.windows[0].id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(defaults.data(forKey: WorkspaceWindowStore.defaultsKey), original)
    }

    func testWindowTeardownOnlyDeletesAnExplicitlyClosedWindow() {
        let defaults = UserDefaults(suiteName: "dev.sora.tests.\(UUID().uuidString)")!
        let store = WorkspaceWindowStore(defaults: defaults, url: url)
        let id = store.windows[0].id
        let snapshot = WorkspaceSnapshot(directories: ["/tmp", "/usr"], selectedIndex: 1)
        XCTAssertTrue(store.save(snapshot, for: id))
        store.close(id, explicitlyRequested: false)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).snapshot(for: id), snapshot)
        store.close(id, explicitlyRequested: true)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults, url: url).windows[0].snapshot, .empty)
    }

    func testSaveAndLoadRoundTrip() {
        let suite = UserDefaults(suiteName: "dev.sora.tests.\(UUID().uuidString)")!
        let snapshot = WorkspaceSnapshot(directories: ["/tmp", "/usr"], selectedIndex: 1)
        WorkspaceRestore.save(snapshot, to: suite)
        XCTAssertEqual(WorkspaceRestore.load(from: suite), snapshot)
    }

    func testMissingKeyLoadsEmptySnapshot() {
        let suite = UserDefaults(suiteName: "dev.sora.tests.\(UUID().uuidString)")!
        XCTAssertEqual(WorkspaceRestore.load(from: suite), .empty)
    }
}
