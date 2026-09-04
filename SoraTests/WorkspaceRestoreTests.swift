import XCTest

final class WorkspaceRestoreTests: XCTestCase {
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
