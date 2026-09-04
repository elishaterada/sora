import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceController

    var body: some View {
        List(selection: Binding(
            get: { workspace.selectedID },
            set: { workspace.select($0) }
        )) {
            ForEach(workspace.tabs) { tab in
                tabRow(tab)
                    .tag(tab.id)
                    .contextMenu {
                        if workspace.tabs.count > 1 {
                            Button("Close Tab", role: .destructive) {
                                workspace.closeTab(id: tab.id)
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspace.addTabInheritingCWD()
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .help("New Tab")
            }
        }
    }

    private func tabRow(_ tab: WorkspaceModel.Tab) -> some View {
        let branch = GitRepository.branchName(containing: tab.workingDirectory)
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SoraTheme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                if let branch {
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(SoraTheme.git)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(tab.displayTitle)
    }
}
