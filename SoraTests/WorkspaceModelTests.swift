import XCTest

final class WorkspaceModelTests: XCTestCase {
    func testInitCreatesOneTabFromEmptySnapshot() {
        let model = WorkspaceModel(snapshot: .empty)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertNil(model.tabs[0].workingDirectory)
    }

    func testAddTabInsertsAfterSelectionAndSelectsIt() {
        let model = WorkspaceModel(snapshot: .empty)
        let first = model.selectedID
        let second = model.addTab(workingDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.selectedID, second)
        XCTAssertEqual(model.tabs[0].id, first)
        XCTAssertEqual(model.tabs[1].workingDirectory?.path, "/tmp")
    }

    func testCloseLastTabIsRejected() {
        let model = WorkspaceModel(snapshot: .empty)
        XCTAssertFalse(model.closeTab(id: model.selectedID))
        XCTAssertEqual(model.tabs.count, 1)
    }

    func testCloseSelectedTabSelectsNeighbor() {
        let model = WorkspaceModel(snapshot: WorkspaceSnapshot(
            directories: ["/a", "/b", "/c"],
            selectedIndex: 1
        ))
        let closed = model.selectedID
        XCTAssertTrue(model.closeTab(id: closed))
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.tabs.map(\.workingDirectory?.path), ["/a", "/c"])
        XCTAssertEqual(model.selected.workingDirectory?.path, "/c")
    }

    func testGotoTabNextPreviousLastAndIndex() {
        let model = WorkspaceModel(snapshot: WorkspaceSnapshot(
            directories: ["/a", "/b", "/c"],
            selectedIndex: 0
        ))
        model.gotoTab(WorkspaceModel.gotoNext)
        XCTAssertEqual(model.selectedIndex, 1)
        model.gotoTab(WorkspaceModel.gotoPrevious)
        XCTAssertEqual(model.selectedIndex, 0)
        model.gotoTab(WorkspaceModel.gotoLast)
        XCTAssertEqual(model.selectedIndex, 2)
        model.gotoTab(1)
        XCTAssertEqual(model.selectedIndex, 0)
        model.gotoTab(99)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testCloseOtherAndRight() {
        let model = WorkspaceModel(snapshot: WorkspaceSnapshot(
            directories: ["/a", "/b", "/c"],
            selectedIndex: 0
        ))
        let keep = model.tabs[0].id
        model.closeTabsToTheRight(of: keep)
        XCTAssertEqual(model.tabs.map(\.workingDirectory?.path), ["/a"])
        _ = model.addTab(workingDirectory: URL(fileURLWithPath: "/b"))
        _ = model.addTab(workingDirectory: URL(fileURLWithPath: "/c"))
        model.select(keep)
        model.closeOtherTabs(keeping: keep)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.selectedID, keep)
    }

    func testSnapshotUsesCurrentDirectories() {
        let model = WorkspaceModel(snapshot: .empty)
        _ = model.addTab(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let snapshot = model.snapshot()
        XCTAssertEqual(snapshot.directories, ["", "/tmp"])
        XCTAssertEqual(snapshot.selectedIndex, 1)
    }

    func testDisplayTitleUsesLastPathComponent() {
        let tab = WorkspaceModel.Tab(
            id: UUID(),
            title: "ignored",
            workingDirectory: URL(fileURLWithPath: "/Users/elisha/repos/sora")
        )
        XCTAssertEqual(tab.displayTitle, "sora")
    }
}
