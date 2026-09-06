import AppKit
import Combine
import GhosttyKit

/// Per-window tab list and PTY ownership. Surfaces are created lazily so
/// SwiftUI `StateObject` throwaway inits do not spawn shells.
final class WorkspaceController: ObservableObject {
    let runtime: GhosttyRuntime
    private let model: WorkspaceModel
    private var surfaces: [UUID: GhosttySurfaceView] = [:]
    private let persist: (WorkspaceSnapshot) -> Void

    @Published private(set) var tabs: [WorkspaceModel.Tab]
    @Published private(set) var selectedID: UUID

    var selected: WorkspaceModel.Tab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    init(
        runtime: GhosttyRuntime,
        snapshot: WorkspaceSnapshot,
        persist: @escaping (WorkspaceSnapshot) -> Void = { WorkspaceRestore.save($0) }
    ) {
        self.runtime = runtime
        self.persist = persist
        self.model = WorkspaceModel(snapshot: snapshot)
        self.tabs = model.tabs
        self.selectedID = model.selectedID
    }

    deinit {
        for view in surfaces.values {
            view.delegate = nil
            view.closeSession()
        }
    }

    func surface(for id: UUID) -> GhosttySurfaceView {
        if let existing = surfaces[id] {
            return existing
        }
        guard let tab = model.tabs.first(where: { $0.id == id }) else {
            preconditionFailure("unknown tab \(id)")
        }
        let view = GhosttySurfaceView(runtime: runtime, workingDirectory: tab.workingDirectory)
        view.delegate = self
        surfaces[id] = view
        return view
    }

    func addTabInheritingCWD() {
        let cwd = surfaces[selectedID]?.currentWorkingDirectory()
            ?? model.selected.workingDirectory
        _ = model.addTab(workingDirectory: cwd)
        publishAndPersist()
    }

    func closeSelectedTab() {
        closeTab(id: selectedID)
    }

    func closeTab(id: UUID) {
        guard model.closeTab(id: id) else {
            persist(model.snapshot())
            NSApp.keyWindow?.performClose(nil)
            return
        }
        retireSurface(id: id)
        publishAndPersist()
    }

    func select(_ id: UUID) {
        model.select(id)
        publish()
    }

    func selectNext() {
        model.selectOffset(1)
        publish()
    }

    func selectPrevious() {
        model.selectOffset(-1)
        publish()
    }

    func gotoTab(_ raw: Int32) {
        model.gotoTab(raw)
        publish()
    }

    /// Agent conversation label for the sidebar/chrome (first user question).
    func updateActivityTitle(_ title: String?, id: UUID) {
        guard model.updateActivityTitle(title, id: id) else { return }
        publish()
    }

    func closedIDs(relativeTo attached: Set<UUID>) -> [UUID] {
        let live = Set(model.tabs.map(\.id))
        return attached.filter { !live.contains($0) }
    }

    func refreshWorkingDirectories() {
        for tab in model.tabs {
            if let url = surfaces[tab.id]?.currentWorkingDirectory() {
                model.updateWorkingDirectory(url, id: tab.id)
            }
        }
        tabs = model.tabs
        persist(model.snapshot())
    }

    /// Push Settings font size into every live Ghostty surface.
    func applyFontSizeToAllSurfaces(_ points: CGFloat = TerminalPreferences.fontSize) {
        for view in surfaces.values {
            view.applyFontSize(points)
        }
    }

    private func publishAndPersist() {
        publish()
        persist(model.snapshot())
    }

    private func publish() {
        tabs = model.tabs
        selectedID = model.selectedID
        let title = model.selected.displayTitle
        runtime.applyTitle(title)
        surfaces[selectedID]?.window?.title = title
    }

    private func retireSurface(id: UUID) {
        guard let view = surfaces.removeValue(forKey: id) else { return }
        view.delegate = nil
        view.closeSession()
        view.removeFromSuperview()
    }

    private func tabID(for view: GhosttySurfaceView) -> UUID? {
        surfaces.first { $0.value === view }?.key
    }
}

extension WorkspaceController: GhosttySurfaceDelegate {
    func surfaceDidRequestClose(_ view: GhosttySurfaceView) {
        guard let id = tabID(for: view) else {
            view.window?.performClose(nil)
            return
        }
        closeTab(id: id)
    }

    func surfaceDidRequestNewTab(_ view: GhosttySurfaceView) {
        _ = view
        addTabInheritingCWD()
    }

    func surface(_ view: GhosttySurfaceView, didRequestGotoTab raw: Int32) {
        _ = view
        gotoTab(raw)
    }

    func surface(_ view: GhosttySurfaceView, didRequestCloseTab mode: ghostty_action_close_tab_mode_e) {
        guard let id = tabID(for: view) else { return }
        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
            let removed = model.tabs.map(\.id).filter { $0 != id }
            model.closeOtherTabs(keeping: id)
            removed.forEach(retireSurface(id:))
            publishAndPersist()
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            guard let index = model.tabs.firstIndex(where: { $0.id == id }) else { return }
            let removed = Array(model.tabs.suffix(from: index + 1).map(\.id))
            model.closeTabsToTheRight(of: id)
            removed.forEach(retireSurface(id:))
            publishAndPersist()
        default:
            closeTab(id: id)
        }
    }

    func surfaceDidRequestCloseWindow(_ view: GhosttySurfaceView) {
        view.window?.performClose(nil)
    }

    func surface(_ view: GhosttySurfaceView, didChangeTitle title: String) {
        guard let id = tabID(for: view) else { return }
        model.updateTitle(title, id: id)
        publish()
    }

    func surface(_ view: GhosttySurfaceView, didChangeWorkingDirectory url: URL) {
        guard let id = tabID(for: view) else { return }
        model.updateWorkingDirectory(url, id: id)
        publishAndPersist()
    }
}
