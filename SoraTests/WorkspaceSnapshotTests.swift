import XCTest

final class WorkspaceSnapshotTests: XCTestCase {
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
