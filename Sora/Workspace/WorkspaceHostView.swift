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

/// Hosts Ghostty surfaces. Window frost lives on `ContentView`; this view stays square.
final class WorkspaceHostView: NSView {
    private var attachedIDs: Set<UUID> = []

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
        for id in workspace.closedIDs(relativeTo: attachedIDs) {
            attachedIDs.remove(id)
        }

        for tab in workspace.tabs {
            let surface = workspace.surface(for: tab.id)
            if surface.superview !== self {
                addSubview(surface)
            }
            surface.autoresizingMask = [.width, .height]
            surface.setActive(tab.id == workspace.selectedID)
            attachedIDs.insert(tab.id)
        }
        layoutSurfaces()
    }

    override func layout() {
        super.layout()
        layoutSurfaces()
    }

    private func layoutSurfaces() {
        for subview in subviews {
            subview.frame = bounds
        }
    }
}
