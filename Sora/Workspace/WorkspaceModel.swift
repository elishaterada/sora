import Foundation

/// Pure tab list. No PTY or view ownership.
final class WorkspaceModel {
    struct Tab: Identifiable, Equatable {
        let id: UUID
        var title: String
        var workingDirectory: URL?

        var displayTitle: String {
            if let workingDirectory {
                let name = workingDirectory.lastPathComponent
                return name.isEmpty ? workingDirectory.path : name
            }
            if title.isEmpty { return "Tab" }
            return title
        }
    }

    /// Ghostty `goto_tab` special values from `ghostty_action_goto_tab_e`.
    static let gotoPrevious: Int32 = -1
    static let gotoNext: Int32 = -2
    static let gotoLast: Int32 = -3

    private(set) var tabs: [Tab]
    private(set) var selectedID: UUID

    var selectedIndex: Int {
        tabs.firstIndex { $0.id == selectedID } ?? 0
    }

    var selected: Tab {
        tabs[selectedIndex]
    }

    init(snapshot: WorkspaceSnapshot) {
        tabs = snapshot.directories.map { path in
            let url = path.isEmpty ? nil : URL(fileURLWithPath: path)
            return Tab(id: UUID(), title: "Tab", workingDirectory: url)
        }
        selectedID = tabs[snapshot.selectedIndex].id
    }

    @discardableResult
    func addTab(workingDirectory: URL?) -> UUID {
        let tab = Tab(
            id: UUID(),
            title: "Tab",
            workingDirectory: workingDirectory
        )
        tabs.insert(tab, at: selectedIndex + 1)
        selectedID = tab.id
        return tab.id
    }

    /// Returns false when `id` is the last tab and it must not be removed.
    @discardableResult
    func closeTab(id: UUID) -> Bool {
        guard tabs.count > 1 else { return false }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return true }
        let wasSelected = tabs[index].id == selectedID
        tabs.remove(at: index)
        if wasSelected {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        return true
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func selectOffset(_ delta: Int) {
        let count = tabs.count
        guard count > 0 else { return }
        let next = (selectedIndex + delta % count + count) % count
        selectedID = tabs[next].id
    }

    func selectLast() {
        guard let last = tabs.last else { return }
        selectedID = last.id
    }

    /// 1-based tab index, or `gotoPrevious` / `gotoNext` / `gotoLast`.
    func gotoTab(_ raw: Int32) {
        switch raw {
        case Self.gotoPrevious:
            selectOffset(-1)
        case Self.gotoNext:
            selectOffset(1)
        case Self.gotoLast:
            selectLast()
        default:
            let index = Int(raw) - 1
            if tabs.indices.contains(index) {
                selectedID = tabs[index].id
            }
        }
    }

    func closeOtherTabs(keeping id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id != id }
        selectedID = id
    }

    func closeTabsToTheRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if index + 1 < tabs.count {
            tabs.removeSubrange((index + 1)...)
        }
        if tabs.contains(where: { $0.id == selectedID }) == false {
            selectedID = id
        }
    }

    func updateTitle(_ title: String, id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = title
    }

    func updateWorkingDirectory(_ url: URL, id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].workingDirectory = url
    }

    func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            directories: tabs.map { $0.workingDirectory?.path ?? "" },
            selectedIndex: selectedIndex
        )
    }
}
