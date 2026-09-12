import XCTest

final class WorkspaceModelTests: XCTestCase {
    func testDragTargetUsesVisibleRowsAndRejectsDropsOutsideSidebar() {
        let first = UUID(), second = UUID(), hidden = UUID()
        let rows = [first: CGRect(x: 6, y: 0, width: 208, height: 28),
                    second: CGRect(x: 6, y: 29, width: 208, height: 48),
                    hidden: CGRect(x: 6, y: -60, width: 208, height: 28)]
        let size = CGSize(width: 220, height: 400)
        XCTAssertEqual(WorkspaceModel.dropTarget(at: CGPoint(x: 60, y: 10), rows: rows, viewport: size), first)
        XCTAssertEqual(WorkspaceModel.dropTarget(at: CGPoint(x: 60, y: 350), rows: rows, viewport: size), second)
        XCTAssertNil(WorkspaceModel.dropTarget(at: CGPoint(x: 221, y: 10), rows: rows, viewport: size))
        XCTAssertNil(WorkspaceModel.dropTarget(at: CGPoint(x: 60, y: -1), rows: rows, viewport: size))
    }

    func testDroppedTabsMoveToDestinationAndPreserveSelectionAndNames() {
        let model = WorkspaceModel(snapshot: WorkspaceSnapshot(directories: ["/a", "/b", "/c"], selectedIndex: 1))
        let ids = model.tabs.map(\.id)
        model.rename(ids[0], name: "Alpha")
        model.move(ids[0], to: ids[2])
        XCTAssertEqual(model.tabs.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(model.selectedID, ids[1])
        model.move(ids[0], to: ids[1])
        XCTAssertEqual(model.tabs.map(\.id), ids)
        model.move(UUID(), to: ids[1])
        model.move(ids[1], to: ids[1])
        XCTAssertEqual(model.tabs.map(\.id), ids)
        XCTAssertEqual(WorkspaceModel(snapshot: model.snapshot()).tabs.first?.displayTitle, "Alpha")
        XCTAssertEqual(WorkspaceModel.TerminalActivity.failed(7).label, "Exit 7")
        XCTAssertTrue(WorkspaceModel.TerminalActivity.failed(7).isFailure)
        XCTAssertFalse(WorkspaceModel.TerminalActivity.running.isFailure)
    }

    func testRenameReorderAndReopenKeepIdentity() {
        let model = WorkspaceModel(snapshot: .empty)
        let first = model.selectedID
        let second = model.addTab(workingDirectory: URL(fileURLWithPath: "/tmp"))
        model.rename(second, name: "  Build logs  ")
        model.move(second, by: -1)
        XCTAssertEqual(model.tabs.first?.id, second)
        XCTAssertEqual(model.selected.displayTitle, "Build logs")
        let restored = WorkspaceModel(snapshot: model.snapshot())
        XCTAssertEqual(restored.selected.displayTitle, "Build logs")
        XCTAssertTrue(model.closeTab(id: second))
        XCTAssertEqual(model.selectedID, first)
        XCTAssertTrue(model.canReopenTab)
        model.reopenTab()
        XCTAssertEqual(model.selectedID, second)
        XCTAssertEqual(model.selected.displayTitle, "Build logs")
        model.rename(second, name: "")
        XCTAssertEqual(model.selected.displayTitle, "tmp")
    }

    func testMovingTabClampsAtEdgesWithoutChangingSelection() {
        let model = WorkspaceModel(snapshot: .empty)
        let first = model.selectedID
        model.move(first, by: -100)
        XCTAssertEqual(model.selectedID, first)
        XCTAssertEqual(model.tabs.count, 1)
    }

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
            title: "Tab",
            activityTitle: nil,
            workingDirectory: URL(fileURLWithPath: "/Users/elisha/repos/sora")
        )
        XCTAssertEqual(tab.displayTitle, "sora")
    }

    func testDisplayTitlePrefersAgentActivityThenShellCommand() {
        let cwd = URL(fileURLWithPath: "/Users/elisha/repos/sora")
        var tab = WorkspaceModel.Tab(
            id: UUID(),
            title: "git status",
            activityTitle: nil,
            workingDirectory: cwd
        )
        XCTAssertEqual(tab.displayTitle, "git status")

        tab.activityTitle = "Find the largest files"
        XCTAssertEqual(tab.displayTitle, "Find the largest files")
        XCTAssertTrue(tab.hasAgentActivity)

        tab.activityTitle = nil
        tab.title = cwd.path
        XCTAssertEqual(tab.displayTitle, "sora")
    }

    func testUpdateActivityTitleStoresTrimmedLabel() {
        let model = WorkspaceModel(snapshot: .empty)
        let id = model.selectedID
        model.updateActivityTitle("  Help me tidy this  ", id: id)
        XCTAssertEqual(model.selected.activityTitle, "Help me tidy this")
        model.updateActivityTitle("   ", id: id)
        XCTAssertNil(model.selected.activityTitle)
    }
}
