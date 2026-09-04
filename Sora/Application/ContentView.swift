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
            Rectangle()
                .fill(SoraTheme.hairline)
                .frame(width: 1)
            VStack(spacing: 0) {
                SessionHeader(workingDirectory: workspace.selected.workingDirectory)
                WorkspaceHostRepresentable(workspace: workspace)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(minWidth: 480, minHeight: 280)
            }
            .background(SoraTheme.ink)
        }
        .background(SoraTheme.sidebar)
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
