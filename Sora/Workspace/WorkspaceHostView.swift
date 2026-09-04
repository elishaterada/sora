import AppKit
import SwiftUI

struct WorkspaceHostRepresentable: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceController

    func makeNSView(context: Context) -> WorkspaceHostView {
        let view = WorkspaceHostView()
        view.sync(workspace: workspace)
        return view
    }

    func updateNSView(_ nsView: WorkspaceHostView, context: Context) {
        nsView.sync(workspace: workspace)
    }
}

/// Hosts terminal panes (Ghostty grid + sticky prompt). Window frost lives on
/// `ContentView`; this view stays square.
final class WorkspaceHostView: NSView {
    private var panes: [UUID: TerminalPaneView] = [:]

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

    func sync(workspace: WorkspaceController) {
        let liveIDs = Set(workspace.tabs.map(\.id))
        for id in panes.keys where !liveIDs.contains(id) {
            panes[id]?.removeFromSuperview()
            panes[id] = nil
        }

        for tab in workspace.tabs {
            let surface = workspace.surface(for: tab.id)
            let pane: TerminalPaneView
            if let existing = panes[tab.id] {
                pane = existing
            } else {
                pane = TerminalPaneView(surface: surface)
                panes[tab.id] = pane
                addSubview(pane)
            }
            if pane.superview !== self {
                addSubview(pane)
            }
            pane.setActive(tab.id == workspace.selectedID)
        }
        layoutPanes()
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    private func layoutPanes() {
        for pane in panes.values {
            pane.frame = bounds
        }
    }
}
