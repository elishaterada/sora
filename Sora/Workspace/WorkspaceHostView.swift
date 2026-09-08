import AppKit
import SwiftUI

struct WorkspaceHostRepresentable: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var ask: AskSession
    let agentTrigger: Int

    func makeNSView(context: Context) -> WorkspaceHostView {
        let view = WorkspaceHostView()
        view.sync(workspace: workspace, ask: ask, agentTrigger: agentTrigger)
        return view
    }

    func updateNSView(_ nsView: WorkspaceHostView, context: Context) {
        nsView.sync(workspace: workspace, ask: ask, agentTrigger: agentTrigger)
    }
}

/// Hosts terminal panes (Ghostty grid + sticky prompt). Window frost lives on
/// `ContentView`; this view stays square.
final class WorkspaceHostView: NSView {
    private let splitView = TerminalSplitContainer()
    private var splitIDs: [UUID] = []
    private var closeDelegate: TerminalWindowCloseDelegate?
    private var panes: [UUID: TerminalPaneView] = [:]
    private var lastAgentTrigger = 0
    private weak var workspace: WorkspaceController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(splitView)
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
        workspace?.restoreFrameIfNeeded(window)
    }

    func sync(workspace: WorkspaceController, ask: AskSession, agentTrigger: Int) {
        self.workspace = workspace
        splitView.onFractionChange = { [weak workspace] fraction in workspace?.splitFraction = fraction }
        closeDelegate?.workspace = workspace
        if let window { workspace.restoreFrameIfNeeded(window) }
        let liveIDs = Set(workspace.tabs.map(\.id))
        for id in panes.keys where !liveIDs.contains(id) {
            panes[id]?.removeFromSuperview()
            panes[id] = nil
            ask.discardTab(id)
        }

        for tab in workspace.tabs {
            let surface = workspace.surface(for: tab.id)
            let pane: TerminalPaneView
            if let existing = panes[tab.id] {
                pane = existing
            } else {
                pane = TerminalPaneView(surface: surface, ask: ask, tabID: tab.id)
                panes[tab.id] = pane
                addSubview(pane)
            }
            pane.onActivityTitleChange = { [weak self] id, title in
                self?.workspace?.updateActivityTitle(title, id: id)
            }
            if pane.superview !== self && pane.superview !== splitView {
                addSubview(pane)
            }
            pane.setActive(tab.id == workspace.selectedID, visible: tab.id == workspace.selectedID || workspace.splitPair.contains(tab.id))
        }
        if splitIDs != workspace.splitPair {
            for pane in panes.values where pane.superview === splitView { pane.removeFromSuperview(); addSubview(pane) }
            splitIDs = workspace.splitPair
            splitView.fraction = workspace.splitFraction
            for id in splitIDs { if let pane = panes[id] { pane.removeFromSuperview(); splitView.addSubview(pane) } }
            splitView.frame = bounds
            splitView.needsLayout = true
            if splitIDs.count == 2 {
                let width = (bounds.width - splitView.dividerThickness) / 2
                for (index, id) in splitIDs.enumerated() {
                    panes[id]?.isHidden = false
                    panes[id]?.frame = NSRect(x: CGFloat(index) * (width + splitView.dividerThickness), y: 0, width: width, height: bounds.height)
                }
            }
        }
        splitView.isHidden = splitIDs.isEmpty
        if window?.isKeyWindow == true { ask.bindTab(workspace.selectedID) }
        layoutPanes()
        for id in splitIDs where id != workspace.selectedID {
            panes[id]?.setActive(false, visible: true)
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
        splitView.frame = bounds
        for pane in panes.values where pane.superview === self {
            pane.frame = bounds
        }
    }
}


/// Preserve SwiftUI's window delegate behavior while guarding destructive closes.
private final class TerminalWindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var workspace: WorkspaceController?
    init(original: NSWindowDelegate?) { self.original = original }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }
    func windowWillClose(_ notification: Notification) {
        workspace?.windowWillClose()
        original?.windowWillClose?(notification)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace?.confirmClose(ids: workspace?.tabs.map(\.id) ?? []) != false else { return false }
        workspace?.refreshWorkingDirectories()
        return original?.windowShouldClose?(sender) ?? true
    }
}


/// Frame-owned split layout avoids intrinsic-size constraints from embedded
/// SwiftUI overlays forcing a terminal pane wider than the available space.
private final class TerminalSplitContainer: NSView {
    var dividerThickness: CGFloat { 1 }
    var fraction: CGFloat = 0.5
    var onFractionChange: ((CGFloat) -> Void)?
    private lazy var divider: TerminalSplitDivider = {
        let view = TerminalSplitDivider()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("Terminal pane divider")
        view.onStep = { [weak self] delta in
            guard let self else { return }
            self.fraction = min(0.8, max(0.2, self.fraction + delta))
            self.onFractionChange?(self.fraction)
            self.needsLayout = true
        }
        view.onDrag = { [weak self] point in
            guard let self else { return }
            self.fraction = min(0.8, max(0.2, point.x / max(1, self.bounds.width)))
            self.onFractionChange?(self.fraction)
            self.needsLayout = true
        }
        return view
    }()
    override func layout() {
        super.layout()
        let panes = subviews.compactMap { $0 as? TerminalPaneView }
        guard panes.count == 2 else { return }
        let width = (bounds.width - 1) * fraction
        panes[0].frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        panes[1].frame = NSRect(x: width + 1, y: 0, width: bounds.width - width - 1, height: bounds.height)
        if divider.superview == nil { addSubview(divider) }
        divider.frame = NSRect(x: width - 3, y: 0, width: 7, height: bounds.height)
    }
}

private final class TerminalSplitDivider: NSView {
    var onDrag: ((NSPoint) -> Void)?
    var onStep: ((CGFloat) -> Void)?
    override func accessibilityPerformIncrement() -> Bool { onStep?(0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { onStep?(-0.05); return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 3, y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) {
        if let superview { onDrag?(superview.convert(event.locationInWindow, from: nil)) }
    }
}
