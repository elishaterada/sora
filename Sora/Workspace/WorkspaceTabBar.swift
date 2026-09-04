import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceController
    @Binding var sidebarVisible: Bool
    var titlebarHeight: CGFloat
    var trafficLightWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chromeRow

            if sidebarVisible {
                Button {
                    workspace.addTabInheritingCWD()
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Tab")
                .padding(.horizontal, 6)
                .padding(.top, 4)

                Text("Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(workspace.tabs) { tab in
                            tabRow(tab)
                        }
                    }
                    .padding(.horizontal, 6)
                }

                Spacer(minLength: 0)

                SessionHeader(workingDirectory: workspace.selected.workingDirectory)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                collapseToggle
                    .padding(.top, 2)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.12))
    }

    private var chromeRow: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: min(trafficLightWidth, 220), height: 1)
            Spacer(minLength: 0)
            if sidebarVisible {
                collapseToggle
            }
        }
        .frame(height: titlebarHeight)
        .padding(.trailing, sidebarVisible ? 6 : 0)
    }

    private var collapseToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }

    private func tabRow(_ tab: WorkspaceModel.Tab) -> some View {
        let selected = tab.id == workspace.selectedID
        let branch = GitRepository.branchName(containing: tab.workingDirectory)
        return Button {
            workspace.select(tab.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if workspace.tabs.count > 1 {
                Button("Close Tab", role: .destructive) {
                    workspace.closeTab(id: tab.id)
                }
            }
        }
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
