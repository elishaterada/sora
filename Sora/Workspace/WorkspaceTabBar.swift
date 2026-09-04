import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceController

    var body: some View {
        List(selection: Binding(
            get: { workspace.selectedID },
            set: { workspace.select($0) }
        )) {
            Button {
                workspace.addTabInheritingCWD()
            } label: {
                Label("New Tab", systemImage: "plus")
            }
            .help("New Tab")

            Section("Sessions") {
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
        }
        .listStyle(.sidebar)
        .listRowSeparator(.hidden)
    }

    private func tabRow(_ tab: WorkspaceModel.Tab) -> some View {
        let branch = GitRepository.branchName(containing: tab.workingDirectory)
        return HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let branch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel(tab.displayTitle)
    }
}
