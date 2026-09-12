import AppKit
import SwiftUI

struct WorkspaceHostRepresentable: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var agents: AgentWorkspace
    let agentTrigger: Int

    func makeNSView(context: Context) -> WorkspaceHostView {
        let view = WorkspaceHostView()
        view.sync(workspace: workspace, agents: agents, agentTrigger: agentTrigger)
        return view
    }

    func updateNSView(_ nsView: WorkspaceHostView, context: Context) {
        nsView.sync(workspace: workspace, agents: agents, agentTrigger: agentTrigger)
    }
}

/// Hosts terminal panes (Ghostty grid + sticky prompt). Window frost lives on
/// `ContentView`; this view stays square.
final class WorkspaceHostView: NSView {
    private var dividers: [UUID: TerminalSplitDivider] = [:]
    private var closeDelegate: TerminalWindowCloseDelegate?
    private var panes: [UUID: TerminalPaneView] = [:]
    private var lastAgentTrigger = 0
    private weak var workspace: WorkspaceController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = SoraTheme.nsClear.cgColor
        layer?.cornerRadius = 0
    }

    override var isOpaque: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, closeDelegate == nil else { return }
        let proxy = TerminalWindowCloseDelegate(original: window.delegate)
        proxy.workspace = workspace
        closeDelegate = proxy
        window.delegate = proxy
        workspace?.runtime.globalShortcut.register(window: window)
        workspace?.restoreFrameIfNeeded(window)
    }

    func sync(workspace: WorkspaceController, agents: AgentWorkspace, agentTrigger: Int) {
        self.workspace = workspace
        workspace.onWindowClose = { [weak agents] in agents?.stopAll() }
        workspace.agentIsBusy = { [weak agents] ids in agents?.isBusy(in: ids) == true }
        closeDelegate?.workspace = workspace
        if let window {
            workspace.runtime.globalShortcut.register(window: window)
            workspace.restoreFrameIfNeeded(window)
        }
        let liveIDs = Set(workspace.tabs.map(\.id))
        for id in panes.keys where !liveIDs.contains(id) {
            panes[id]?.removeFromSuperview()
            panes[id] = nil
            agents.discard(id)
        }

        for tab in workspace.tabs {
            let surface = workspace.surface(for: tab.id)
            let pane: TerminalPaneView
            if let existing = panes[tab.id] {
                pane = existing
            } else {
                pane = TerminalPaneView(surface: surface, ask: agents.session(for: tab.id), tabID: tab.id)
                panes[tab.id] = pane
                addSubview(pane)
            }
            pane.onAgentBusyChange = { [weak workspace] id, busy in workspace?.updateAgentBusy(busy, id: id) }
            pane.onActivityTitleChange = { [weak self] id, title in
                self?.workspace?.updateActivityTitle(title, id: id)
            }
            if pane.superview !== self { addSubview(pane) }
        }
        layoutPanes()
        let visible = Set(workspace.displayedPaneLayout.leaves)
        for (id, pane) in panes where id != workspace.selectedID {
            pane.setActive(false, visible: visible.contains(id))
        }
        panes[workspace.selectedID]?.setActive(true, visible: true)
        if agentTrigger != lastAgentTrigger {
            lastAgentTrigger = agentTrigger
            panes[workspace.selectedID]?.showAgent()
        }
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    private func layoutPanes() {
        guard let workspace else { return }
        let geometry = workspace.displayedPaneLayout.geometry(in: bounds)
        for (id, pane) in panes {
            if let frame = geometry.panes[id] { pane.frame = frame }
            pane.isHidden = geometry.panes[id] == nil
        }
        let live = Set(geometry.dividers.map(\.id))
        for id in Array(dividers.keys) where !live.contains(id) {
            dividers.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in geometry.dividers {
            let divider = dividers[item.id] ?? TerminalSplitDivider()
            dividers[item.id] = divider
            if divider.superview == nil { addSubview(divider, positioned: .above, relativeTo: nil) }
            divider.axis = item.axis
            divider.frame = item.frame
            divider.setAccessibilityLabel(item.axis == .right ? "Side-by-side pane divider" : "Stacked pane divider")
            divider.onStep = { [weak workspace] delta in
                workspace?.resizeSplit(item.id, fraction: item.fraction + delta, commit: true)
            }
            divider.onDrag = { [weak workspace] point, commit in
                let length = item.axis == .right ? item.container.width : item.container.height
                let offset = item.axis == .right ? point.x - item.container.minX : item.container.maxY - point.y
                workspace?.resizeSplit(item.id, fraction: offset / max(1, length - 1), commit: commit)
            }
        }
    }

}


/// Preserve SwiftUI's window delegate behavior while guarding destructive closes.
private final class TerminalWindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var workspace: WorkspaceController?
    private var explicitlyClosed = false
    init(original: NSWindowDelegate?) { self.original = original }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }
    func windowWillClose(_ notification: Notification) {
        workspace?.windowWillClose(explicitlyClosed: explicitlyClosed)
        original?.windowWillClose?(notification)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace?.confirmClose(ids: workspace?.tabs.map(\.id) ?? []) != false else { return false }
        workspace?.refreshWorkingDirectories()
        let approved = original?.windowShouldClose?(sender) ?? true
        explicitlyClosed = approved
        return approved
    }
}


/// Dividers share the host coordinate space with all panes. Resizing and
/// maximizing never reparent terminal surfaces or replace a PTY.
private final class TerminalSplitDivider: NSView {
    var axis: PaneSplitAxis = .right {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    var onDrag: ((NSPoint, Bool) -> Void)?
    var onStep: ((Double) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func accessibilityPerformIncrement() -> Bool { onStep?(0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { onStep?(-0.05); return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        (axis == .right ? NSRect(x: 3, y: 0, width: 1, height: bounds.height)
            : NSRect(x: 0, y: 3, width: bounds.width, height: 1)).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: axis == .right ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        if let superview { onDrag?(superview.convert(event.locationInWindow, from: nil), false) }
    }
    override func mouseUp(with event: NSEvent) {
        if let superview { onDrag?(superview.convert(event.locationInWindow, from: nil), true) }
    }
}
