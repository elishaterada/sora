import Foundation

/// Pure tab list. No PTY or view ownership.
final class WorkspaceModel {
    struct Tab: Identifiable, Equatable {
        let id: UUID
        /// Shell OSC / Ghostty title (often the last command).
        var customName: String? = nil
        var title: String
        /// Agent thread label from the first user question; wins over shell title.
        var activityTitle: String?
        var workingDirectory: URL?

        var hasAgentActivity: Bool {
            activityTitle.map { !$0.isEmpty } ?? false
        }

        /// Prefer agent task → recent shell title → folder name.
        var displayTitle: String {
            if let customName, !customName.isEmpty { return customName }
            if let activityTitle, !activityTitle.isEmpty {
                return activityTitle
            }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "Tab", trimmed != "Sora" {
                if let workingDirectory,
                   CommandRunFactory.isWorkingDirectoryTitle(trimmed, cwd: workingDirectory) {
                    // fall through to folder name
                } else {
                    return trimmed
                }
            }
            if let workingDirectory {
                let name = workingDirectory.lastPathComponent
                return name.isEmpty ? workingDirectory.path : name
            }
            return "Tab"
        }
    }

    /// Ghostty `goto_tab` special values from `ghostty_action_goto_tab_e`.
    static let gotoPrevious: Int32 = -1
    static let gotoNext: Int32 = -2
    static let gotoLast: Int32 = -3

    private var closedTabs: [Tab] = []
    var canReopenTab: Bool { !closedTabs.isEmpty }
    private(set) var tabs: [Tab]
    private(set) var selectedID: UUID

    var selectedIndex: Int {
        tabs.firstIndex { $0.id == selectedID } ?? 0
    }

    var selected: Tab {
        tabs[selectedIndex]
    }

    init(snapshot: WorkspaceSnapshot) {
        tabs = snapshot.directories.enumerated().map { index, path in
            let url = path.isEmpty ? nil : URL(fileURLWithPath: path)
            return Tab(id: snapshot.sessionIDs.flatMap { index < $0.count ? $0[index] : nil } ?? UUID(), customName: snapshot.tabNames.flatMap { index < $0.count ? $0[index] : nil }, title: "Tab", activityTitle: nil, workingDirectory: url)
        }
        selectedID = tabs[min(max(0, snapshot.selectedIndex), tabs.count - 1)].id
    }

    @discardableResult
    func addTab(workingDirectory: URL?) -> UUID {
        let tab = Tab(
            id: UUID(),
            title: "Tab",
            activityTitle: nil,
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
        closedTabs.append(tabs[index])
        if closedTabs.count > 10 { closedTabs.removeFirst() }
        tabs.remove(at: index)
        if wasSelected {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        return true
    }

    func rename(_ id: UUID, name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].customName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(tabs.count - 1, max(0, index + offset))
        let tab = tabs.remove(at: index)
        tabs.insert(tab, at: destination)
    }

    func reopenTab() {
        guard let tab = closedTabs.popLast() else { return }
        tabs.insert(tab, at: selectedIndex + 1)
        selectedID = tab.id
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

    @discardableResult
    func updateActivityTitle(_ title: String?, id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (trimmed?.isEmpty == false) ? trimmed : nil
        guard tabs[index].activityTitle != next else { return false }
        tabs[index].activityTitle = next
        return true
    }

    func updateWorkingDirectory(_ url: URL, id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].workingDirectory = url
    }

    func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            directories: tabs.map { $0.workingDirectory?.path ?? "" },
            selectedIndex: selectedIndex,
            sessionIDs: tabs.map(\.id),
            tabNames: tabs.map { $0.customName ?? "" }
        )
    }
}
