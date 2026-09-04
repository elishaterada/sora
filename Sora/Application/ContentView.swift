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
        VStack(spacing: 0) {
            WorkspaceTabBar(workspace: workspace)
            Divider()
            WorkspaceHostRepresentable(workspace: workspace)
                .frame(minWidth: 400, minHeight: 240)
        }
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
