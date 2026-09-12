import AppKit
import Combine
import GhosttyKit

/// Per-window tab list and PTY ownership. Surfaces are created lazily so
/// SwiftUI `StateObject` throwaway inits do not spawn shells.
final class WorkspaceController: ObservableObject {
    let runtime: GhosttyRuntime
    let windowID: UUID
    private let restoredFrame: String?
    private var hasRestoredFrame = false
    private var isClosed = false
    private var startedPersistence = false
    private var commandPalette: CommandPaletteController?
    private let model: WorkspaceModel
    private var surfaces: [UUID: GhosttySurfaceView] = [:]
    private var historyTimer: Timer?
    private let historyWriter = TerminalHistoryWriter()
    private var persistenceObservers: [NSObjectProtocol] = []
    private let persist: (WorkspaceSnapshot) -> Bool

    var onWindowClose: (() -> Void)?
    var agentIsBusy: (([UUID]) -> Bool)?
    var ownsKeyWindow: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return surfaces.values.contains { $0.window === window }
    }

    @Published private(set) var paneLayout: PaneLayout<UUID>?
    @Published private(set) var isPaneMaximized = false
    var hasSelectedSplit: Bool { paneLayout?.leaves.contains(selectedID) == true }
    var displayedPaneLayout: PaneLayout<UUID> {
        hasSelectedSplit && !isPaneMaximized ? paneLayout! : .leaf(selectedID)
    }
    @Published private(set) var activities: [UUID: WorkspaceModel.TerminalActivity] = [:]
    @Published private(set) var busyAgents: Set<UUID> = []
    @Published private(set) var attention: [UUID: String] = [:]
    var canReopenTab: Bool { model.canReopenTab }
    @Published private(set) var tabs: [WorkspaceModel.Tab]
    @Published private(set) var selectedID: UUID

    var selected: WorkspaceModel.Tab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    init(
        runtime: GhosttyRuntime,
        snapshot: WorkspaceSnapshot,
        windowID: UUID = UUID(),
        persist: ((WorkspaceSnapshot) -> Bool)? = nil
    ) {
        self.runtime = runtime
        self.windowID = windowID
        self.restoredFrame = snapshot.windowFrame
        self.persist = persist ?? { [weak runtime] snapshot in runtime?.windowStore.save(snapshot, for: windowID) ?? false }
        self.model = WorkspaceModel(snapshot: snapshot)
        self.tabs = model.tabs
        self.selectedID = model.selectedID
        paneLayout = snapshot.restoredPaneLayout()
        isPaneMaximized = snapshot.isPaneMaximized == true && paneLayout?.leaves.contains(model.selectedID) == true
    }

    func startPersistence() {
        guard !startedPersistence else { return }
        startedPersistence = true
        self.historyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshWorkingDirectories()
        }
        for name in [WorkspaceWindowStore.terminationApproved, NSApplication.willTerminateNotification,
                     WorkspaceWindowStore.checkpointRequested] {
            persistenceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                // These lifecycle notifications originate on the owning main thread.
                if name != WorkspaceWindowStore.checkpointRequested { self.runtime.windowStore.isTerminating = true }
                self.refreshWorkingDirectories()
                self.historyWriter.flush()
            })
        }
        _ = persist(snapshotForSave())
    }

    deinit {
        historyTimer?.invalidate()
        persistenceObservers.forEach(NotificationCenter.default.removeObserver)
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
        let view = GhosttySurfaceView(runtime: runtime, tabID: tab.id, workingDirectory: tab.workingDirectory)
        view.historyArchiveURL = TerminalHistoryArchive.url(for: id)
        view.onFocus = { [weak self] in
            guard let self, self.selectedID != id else { return }
            self.select(id)
        }
        view.onCommandStarted = { [weak self] in
            self?.activities[id] = .running
            self?.attention[id] = nil
        }
        view.onCommandFinished = { [weak self] code in
            guard let self, code >= 0 else { return }
            self.activities[id] = code == 0 ? .finished : .failed(code)
            if id != self.selectedID || !NSApp.isActive { self.attention[id] = code == 0 ? "Finished" : "Exit \(code)" }
        }
        view.onNotificationActivate = { [weak self] in
            guard let self else { return }
            let window = self.surfaces.values.compactMap { $0.window }.first
            self.select(id)
            window?.makeKeyAndOrderFront(nil)
        }
        view.onBell = { [weak self] in self?.attention[id] = "Attention" }
        view.delegate = self
        surfaces[id] = view
        return view
    }

    func canSplit(_ axis: PaneSplitAxis) -> Bool {
        guard !hasSelectedSplit || (paneLayout?.leaves.count ?? 0) < PaneLayout<UUID>.maximumPanes else { return false }
        guard let pane = surfaces[selectedID]?.superview else { return false }
        let size = isPaneMaximized && hasSelectedSplit
            ? paneLayout?.geometry(in: pane.superview?.bounds ?? .zero).panes[selectedID]?.size ?? .zero : pane.bounds.size
        return axis == .right ? size.width >= 440 : size.height >= 440
    }

    func splitTerminal(axis: PaneSplitAxis = .right) {
        guard canSplit(axis) else { return }
        let previous = selectedID
        let next = model.addTab(workingDirectory: surfaces[previous]?.currentWorkingDirectory() ?? model.selected.workingDirectory)
        let tree = hasSelectedSplit ? paneLayout! : .leaf(previous)
        paneLayout = tree.splitting(previous, adding: next, axis: axis)
        isPaneMaximized = false
        publishAndPersist()
    }
    func endSplit() { paneLayout = nil; isPaneMaximized = false; publishAndPersist() }
    func togglePaneMaximized() {
        guard hasSelectedSplit else { return }
        isPaneMaximized.toggle()
        publishAndPersist()
    }
    func focusPane(_ direction: PaneFocusDirection) {
        guard hasSelectedSplit, let next = paneLayout?.neighbor(of: selectedID, direction: direction) else { return }
        select(next)
    }
    func resizeSplit(_ id: UUID, fraction: Double, commit: Bool) {
        paneLayout = paneLayout?.settingFraction(fraction, for: id)
        if commit { _ = persist(snapshotForSave()) }
    }

    func findOutput() { surfaces[selectedID]?.showFind() }

    func showCommandPalette() {
        guard let window = surfaces[selectedID]?.window, window.attachedSheet == nil else { return }
        let palette = CommandPaletteController(workspace: self)
        commandPalette = palette
        palette.onClose = { [weak self] in self?.commandPalette = nil }
        palette.present(in: window)
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

    func confirmClose(ids: [UUID]) -> Bool {
        guard ids.contains(where: { surfaces[$0]?.hasRunningTask == true }) || agentIsBusy?(ids) == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Close running tasks?"
        alert.informativeText = "Closing these sessions will stop their terminal commands and Agent requests. Output history will be saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Sessions")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func renameTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave the name empty to use the automatic title."
        let input = NSTextField(string: tab.customName ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn { model.rename(id, name: input.stringValue); publishAndPersist() }
    }
    func moveTab(_ id: UUID, by offset: Int) { model.move(id, by: offset); publishAndPersist() }
    func moveTab(_ id: UUID, to target: UUID) { model.move(id, to: target); publishAndPersist() }
    func updateAgentBusy(_ busy: Bool, id: UUID) {
        guard busyAgents.contains(id) != busy else { return }
        if busy { busyAgents.insert(id) } else { busyAgents.remove(id) }
    }
    func reopenTab() { model.reopenTab(); publishAndPersist() }

    func closeTab(id: UUID) {
        if tabs.count == 1 {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        guard confirmClose(ids: [id]) else { return }
        refreshWorkingDirectories()
        let neighbor = paneLayout?.focusAfterRemoving(id)
        let closedSelectedPane = selectedID == id && hasSelectedSplit
        guard model.closeTab(id: id) else {
            _ = persist(snapshotForSave())
            NSApp.keyWindow?.performClose(nil)
            return
        }
        retireSurface(id: id)
        if closedSelectedPane, let neighbor { model.select(neighbor) }
        publishAndPersist()
    }

    func select(_ id: UUID) {
        attention[id] = nil
        model.select(id)
        publishAndPersist()
    }

    func selectNext() {
        model.selectOffset(1)
        publishAndPersist()
    }

    func selectPrevious() {
        model.selectOffset(-1)
        publishAndPersist()
    }

    func gotoTab(_ raw: Int32) {
        model.gotoTab(raw)
        publishAndPersist()
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

    private func saveHistories() {
        for (id, view) in surfaces where view.canCheckpointHistory {
            historyWriter.enqueue(.init(id: id, text: view.historyText(), draft: view.draftText))
        }
    }

    func refreshWorkingDirectories() {
        guard !isClosed else { return }
        for tab in model.tabs {
            if let url = surfaces[tab.id]?.currentWorkingDirectory() {
                model.updateWorkingDirectory(url, id: tab.id)
            }
        }
        tabs = model.tabs
        if persist(snapshotForSave()) { saveHistories() }
    }

    func applyShortcutsToAllSurfaces() {
        for view in surfaces.values { view.applyShortcuts() }
        objectWillChange.send()
    }

    func applyAppearanceToAllSurfaces() {
        for view in surfaces.values { view.applyAppearance() }
        objectWillChange.send()
    }

    /// Push Settings font size into every live Ghostty surface.
    func applyFontSizeToAllSurfaces(_ points: CGFloat = TerminalPreferences.fontSize) {
        for view in surfaces.values {
            view.applyFontSize(points)
        }
    }

    func restoreFrameIfNeeded(_ window: NSWindow) {
        guard !hasRestoredFrame else { return }
        hasRestoredFrame = true
        guard let restoredFrame else { return }
        let frame = NSRectFromString(restoredFrame)
        guard frame.width >= 640, frame.height >= 400,
              frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: true)
    }

    func windowWillClose(explicitlyClosed: Bool) {
        onWindowClose?()
        refreshWorkingDirectories()
        isClosed = true
        historyTimer?.invalidate()
        historyWriter.flush()
        runtime.windowStore.close(windowID, explicitlyRequested: explicitlyClosed)
    }

    func projectLayoutSnapshot() -> WorkspaceSnapshot {
        refreshWorkingDirectories()
        return snapshotForSave()
    }

    private func snapshotForSave() -> WorkspaceSnapshot {
        var snapshot = model.snapshot()
        snapshot.paneLayout = paneLayout
        snapshot.isPaneMaximized = isPaneMaximized
        // Keep the legacy pair fields for an older build's simple layouts.
        if case .split(_, .right, let fraction, .leaf(let first), .leaf(let second)) = paneLayout {
            snapshot.splitIDs = [first, second]
            snapshot.splitFraction = fraction
        }
        snapshot.windowFrame = surfaces.values.compactMap { $0.window }.first.map { NSStringFromRect($0.frame) } ?? restoredFrame
        return snapshot
    }

    private func publishAndPersist() {
        guard !isClosed else { return }
        publish()
        _ = persist(snapshotForSave())
    }

    private func publish() {
        tabs = model.tabs
        selectedID = model.selectedID
        attention[selectedID] = nil
        paneLayout = paneLayout?.retaining(Set(tabs.map(\.id)))
        if paneLayout?.isSplit != true { paneLayout = nil }
        if !hasSelectedSplit { isPaneMaximized = false }
        let title = model.selected.displayTitle
        runtime.applyTitle(title)
        surfaces[selectedID]?.window?.title = title
    }

    private func retireSurface(id: UUID) {
        activities[id] = nil
        attention[id] = nil
        busyAgents.remove(id)
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
            guard confirmClose(ids: removed) else { return }
            refreshWorkingDirectories()
            model.closeOtherTabs(keeping: id)
            removed.forEach(retireSurface(id:))
            publishAndPersist()
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            guard let index = model.tabs.firstIndex(where: { $0.id == id }) else { return }
            let removed = Array(model.tabs.suffix(from: index + 1).map(\.id))
            guard confirmClose(ids: removed) else { return }
            refreshWorkingDirectories()
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
