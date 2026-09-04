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

final class WorkspaceHostView: NSView {
    private var attachedIDs: Set<UUID> = []

    override var isFlipped: Bool { false }

    func sync(workspace: WorkspaceController) {
        for id in workspace.closedIDs(relativeTo: attachedIDs) {
            attachedIDs.remove(id)
        }

        for tab in workspace.tabs {
            let surface = workspace.surface(for: tab.id)
            if surface.superview !== self {
                addSubview(surface)
            }
            surface.frame = bounds
            surface.autoresizingMask = [.width, .height]
            surface.setActive(tab.id == workspace.selectedID)
            attachedIDs.insert(tab.id)
        }
    }

    override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }
    }
}
