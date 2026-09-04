import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var runtime: GhosttyRuntime
    @StateObject private var workspace: WorkspaceController

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        _workspace = StateObject(
            wrappedValue: WorkspaceController(
                runtime: runtime,
                snapshot: runtime.peekRestoreSnapshot()
            )
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceTabBar(workspace: workspace)
                .frame(width: 220)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
            WorkspaceHostRepresentable(workspace: workspace)
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        }
        .background(WindowFrostRepresentable().ignoresSafeArea())
        .modifier(ClearWindowBackground())
        .toolbar(.hidden, for: .windowToolbar)
        .preferredColorScheme(.dark)
        .focusedSceneObject(workspace)
        .onAppear {
            runtime.markRestoreConsumed()
            runtime.setFocus(NSApp.isActive)
        }
        .onDisappear {
            workspace.refreshWorkingDirectories()
        }
    }
}

/// Full-window frost. Corner radius stays 0 so this is not a floating card.
struct WindowFrostRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = SoraTheme.nsGlassTint
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 0
        return effect
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.cornerRadius = 0
    }
}

private struct ClearWindowBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}
