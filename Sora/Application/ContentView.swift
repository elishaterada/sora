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
                .navigationSplitViewColumnWidth(min: 176, ideal: 220, max: 280)
        } detail: {
            WorkspaceHostRepresentable(workspace: workspace)
                .padding(12)
                .frame(minWidth: 480, minHeight: 280)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        SessionHeader(workingDirectory: workspace.selected.workingDirectory)
                    }
                }
                .navigationTitle(workspace.selected.displayTitle)
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
