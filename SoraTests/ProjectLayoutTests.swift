import XCTest

final class ProjectLayoutTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sora-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in ["api", "web"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func source(_ root: URL) -> WorkspaceSnapshot {
        let ids = [UUID(), UUID()]
        var snapshot = WorkspaceSnapshot(directories: [root.appendingPathComponent("api").path, root.appendingPathComponent("web").path],
            selectedIndex: 1, sessionIDs: ids, tabNames: ["Backend", "Frontend"])
        snapshot.splitIDs = ids
        snapshot.splitFraction = 0.35
        snapshot.windowFrame = "{{100, 100}, {900, 600}}"
        return snapshot
    }
    func testLayoutReopensStructureWithFreshIdentitiesAndNoHistoryReferences() throws {
        let root = try fixture()
        let source = source(root)
        let layout = try ProjectLayout(name: "  Example Project  ", snapshot: source)
        let first = try layout.snapshot(), second = try layout.snapshot()
        XCTAssertEqual(layout.name, "Example Project")
        XCTAssertEqual(first.directories, source.directories)
        XCTAssertEqual(first.tabNames, source.tabNames)
        XCTAssertEqual(first.selectedIndex, 1)
        XCTAssertEqual(first.splitIDs, first.sessionIDs)
        XCTAssertEqual(first.splitFraction, 0.35)
        XCTAssertNil(first.windowFrame)
        XCTAssertTrue(Set(first.sessionIDs!).isDisjoint(with: source.sessionIDs!))
        XCTAssertTrue(Set(first.sessionIDs!).isDisjoint(with: second.sessionIDs!))
        let bytes = try JSONEncoder().encode(layout)
        let text = String(decoding: bytes, as: UTF8.self)
        for id in source.sessionIDs! { XCTAssertFalse(text.contains(id.uuidString)) }
        XCTAssertFalse(text.contains("history"))
        XCTAssertFalse(text.contains("draft"))
        XCTAssertEqual(try JSONDecoder().decode(ProjectLayout.self, from: bytes), layout)
    }
    func testMissingFoldersRequireExplicitReplacementWithoutChangingTemplate() throws {
        let root = try fixture()
        let layout = try ProjectLayout(name: "Missing folder", snapshot: source(root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("web"))
        XCTAssertEqual(layout.missingFolders(), [1])
        XCTAssertThrowsError(try layout.snapshot())
        let resolved = try layout.snapshot(replacements: [1: root.appendingPathComponent("api")])
        XCTAssertEqual(resolved.directories[1], root.appendingPathComponent("api").path)
        XCTAssertEqual(layout.tabs[1].directory, root.appendingPathComponent("web").path)
        XCTAssertThrowsError(try layout.snapshot(replacements: [1: URL(string: "https://example.com")!]))
        try Data().write(to: root.appendingPathComponent("web"))
        XCTAssertEqual(layout.missingFolders(), [1]) // A regular file is not a usable working folder.
    }
    func testNestedTemplateMapsPaneIndicesToFreshSessions() throws {
        let root = try fixture()
        let ids = [UUID(), UUID(), UUID()]
        var snapshot = WorkspaceSnapshot(directories: [root.path, root.path, root.path], selectedIndex: 2, sessionIDs: ids)
        snapshot.paneLayout = .leaf(ids[0]).splitting(ids[0], adding: ids[1], axis: .below)
            .splitting(ids[1], adding: ids[2], axis: .right)
        snapshot.isPaneMaximized = true
        let layout = try ProjectLayout(name: "Nested", snapshot: snapshot)
        XCTAssertEqual(layout.paneLayout?.leaves, [0, 1, 2])
        XCTAssertTrue(layout.hasSplit)
        let restored = try layout.snapshot()
        XCTAssertTrue(Set(restored.sessionIDs!).isDisjoint(with: ids))
        XCTAssertEqual(restored.paneLayout?.leaves, restored.sessionIDs)
        XCTAssertEqual(restored.paneLayout?.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 800)).dividers.map(\.axis), [.below, .right])
        XCTAssertNil(restored.isPaneMaximized) // Templates open the complete arrangement.
        var invalid = layout
        invalid.paneLayout = .leaf(99)
        XCTAssertThrowsError(try invalid.snapshot())
    }
    func testCatalogMergesIndependentChangesAndRejectsStaleMutation() throws {
        let root = try fixture(), url = root.appendingPathComponent("Layouts/layouts.json")
        let first = ProjectLayoutStore(url: url), second = ProjectLayoutStore(url: url)
        let one = try first.save(name: "One", snapshot: source(root))
        let two = try second.save(name: "Two", snapshot: source(root))
        try first.rename(one, to: "Renamed")
        XCTAssertThrowsError(try second.delete(one))
        XCTAssertEqual(ProjectLayoutStore(url: url).layouts.map(\.name), ["Renamed", "Two"])
        try first.delete(two)
        _ = try second.save(name: "Three", snapshot: source(root))
        XCTAssertEqual(ProjectLayoutStore(url: url).layouts.map(\.name), ["Renamed", "Three"])
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try first.save(name: "RENAMED", snapshot: source(root)))
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testCatalogRecoversBackupAndProtectsFutureVersions() throws {
        let root = try fixture(), url = root.appendingPathComponent("Layouts/layouts.json")
        let store = ProjectLayoutStore(url: url)
        _ = try store.save(name: "One", snapshot: source(root))
        _ = try store.save(name: "Two", snapshot: source(root))
        let broken = Data("broken catalog".utf8)
        try broken.write(to: url)
        let recovered = ProjectLayoutStore(url: url)
        XCTAssertEqual(recovered.layouts.map(\.name), ["One"])
        XCTAssertNotNil(recovered.recoveryMessage)
        let preserved = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unreadable-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), broken)
        let future = Data("{\"version\":2,\"layouts\":[]}".utf8)
        try future.write(to: url)
        let newer = ProjectLayoutStore(url: url)
        XCTAssertNotNil(newer.errorMessage)
        XCTAssertThrowsError(try newer.save(name: "No overwrite", snapshot: source(root)))
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertThrowsError(try ProjectLayout(name: "\n", snapshot: source(root)))
        XCTAssertThrowsError(try ProjectLayout(name: "Too many", snapshot: WorkspaceSnapshot(directories: Array(repeating: "", count: 65), selectedIndex: 0)))
    }
}
