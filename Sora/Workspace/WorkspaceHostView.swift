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

/// Hosts Ghostty surfaces over liquid glass. libghostty paints cells with alpha
/// but does not install `NSGlassEffectView` in the embedder.
final class WorkspaceHostView: NSView {
    private var attachedIDs: Set<UUID> = []
    private let terminalContent = NSView()
    private let backdrop: NSView

    override init(frame frameRect: NSRect) {
        backdrop = Self.makeBackdrop(content: terminalContent)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = SoraTheme.nsClear.cgColor
        addSubview(backdrop)
        terminalContent.autoresizingMask = [.width, .height]
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
            if surface.superview !== terminalContent {
                terminalContent.addSubview(surface)
            }
            surface.autoresizingMask = [.width, .height]
            surface.setActive(tab.id == workspace.selectedID)
            attachedIDs.insert(tab.id)
        }
        layoutSurfaces()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        if backdrop is NSVisualEffectView {
            terminalContent.frame = backdrop.bounds
        }
        layoutSurfaces()
    }

    private func layoutSurfaces() {
        let frame = terminalContent.bounds
        for subview in terminalContent.subviews {
            subview.frame = frame
        }
    }

    private static func makeBackdrop(content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = SoraTheme.terminalCornerRadius
            glass.tintColor = SoraTheme.nsGlassTint
            glass.contentView = content
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = SoraTheme.terminalCornerRadius
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        content.frame = effect.bounds
        return effect
    }
}
