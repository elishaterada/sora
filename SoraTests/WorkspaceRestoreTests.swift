import XCTest

final class WorkspaceRestoreTests: XCTestCase {
    func testWindowCatalogMigratesLegacyWithoutLosingTabIDs() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let snapshot = WorkspaceSnapshot(directories: ["/tmp"], selectedIndex: 0, sessionIDs: [id], tabNames: ["Build"])
        WorkspaceRestore.save(snapshot, to: defaults)
        let store = WorkspaceWindowStore(defaults: defaults)
        XCTAssertEqual(store.windows.count, 1)
        XCTAssertEqual(store.windows[0].snapshot, snapshot)
        store.save(snapshot, for: store.windows[0].id)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults).windows, store.windows)
    }

    func testWindowUpdatesAndCloseDoNotOverwriteOtherWindows() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceWindowStore(defaults: defaults)
        let first = store.windows[0].id
        let second = UUID()
        var a = WorkspaceSnapshot(directories: ["/tmp", "/usr"], selectedIndex: 1, sessionIDs: [UUID(), UUID()])
        a.splitIDs = a.sessionIDs
        a.windowFrame = "{{10, 20}, {900, 600}}"
        let b = WorkspaceSnapshot(directories: ["/var"], selectedIndex: 0, sessionIDs: [UUID()])
        store.save(a, for: first)
        store.save(b, for: second)
        let loaded = WorkspaceWindowStore(defaults: defaults)
        XCTAssertEqual(loaded.snapshot(for: first), a)
        XCTAssertEqual(loaded.snapshot(for: second), b)
        loaded.close(second)
        XCTAssertEqual(loaded.windows.map(\.id), [first])
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults).snapshot(for: first), a)
        loaded.isTerminating = true
        loaded.close(first)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults).windows.count, 1)
    }

    func testClosingLastWindowDoesNotResurrectLegacyTabs() {
        let name = "dev.sora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        WorkspaceRestore.save(WorkspaceSnapshot(directories: ["/old"], selectedIndex: 0), to: defaults)
        let store = WorkspaceWindowStore(defaults: defaults)
        store.close(store.windows[0].id)
        XCTAssertEqual(WorkspaceWindowStore(defaults: defaults).windows[0].snapshot, .empty)
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
