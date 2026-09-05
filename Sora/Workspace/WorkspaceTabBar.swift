import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceController
    @Binding var sidebarVisible: Bool
    var titlebarHeight: CGFloat
    var trafficLightWidth: CGFloat
    var onAsk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chromeRow

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

            Button(action: onAsk) {
                Label("Agent", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Agent (⌘⇧A)")
            .padding(.horizontal, 6)
            .padding(.top, 2)

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.12))
    }

    private var chromeRow: some View {
        HStack(spacing: 2) {
            Color.clear
                .frame(width: min(trafficLightWidth, 220), height: 1)
            SidebarToggleButton(sidebarVisible: $sidebarVisible)
            Spacer(minLength: 0)
        }
        .frame(height: titlebarHeight)
        .padding(.trailing, 6)
    }

    private func tabRow(_ tab: WorkspaceModel.Tab) -> some View {
        let selected = tab.id == workspace.selectedID
        let branch = GitRepository.branchName(containing: tab.workingDirectory)
        return Button {
            workspace.select(tab.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.hasAgentActivity
                      ? "bubble.left.and.text.bubble.right.fill"
                      : "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tab.hasAgentActivity ? Color.accentColor : .secondary)
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
