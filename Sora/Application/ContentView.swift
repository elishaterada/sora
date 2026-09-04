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
        NavigationSplitView {
            WorkspaceTabBar(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            WorkspaceHostRepresentable(workspace: workspace)
                .frame(minWidth: 480, minHeight: 280)
                .navigationTitle(workspace.selected.displayTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        SessionHeader(workingDirectory: workspace.selected.workingDirectory)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
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
