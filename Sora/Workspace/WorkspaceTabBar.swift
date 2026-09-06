import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceController
    @Binding var sidebarVisible: Bool
    var titlebarHeight: CGFloat
    var trafficLightWidth: CGFloat
    var onAsk: () -> Void

    private var selectedBranch: String? {
        GitRepository.branchName(containing: workspace.selected.workingDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chromeRow

            Button {
                workspace.addTabInheritingCWD()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .font(SoraTheme.chromeBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoraChromeButtonStyle())
            .help("New Tab")
            .padding(.horizontal, 6)
            .padding(.top, SoraTheme.space1)

            Button(action: onAsk) {
                Label("Agent", systemImage: "sparkles")
                    .font(SoraTheme.chromeBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoraChromeButtonStyle())
            .help("Open Agent (⌘⇧A)")
            .accessibilityLabel("Open Agent")
            .padding(.horizontal, 6)
            .padding(.top, 2)

            Text("Sessions")
                .font(SoraTheme.chromeCaptionSemibold)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, SoraTheme.space4)
                .padding(.top, SoraTheme.space4)
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
            // Path/branch live in the chrome bar and sticky prompt — keep the
            // sidebar focused on session identity.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SoraTheme.sidebarWash)
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
        // Only show a branch subtitle when it differs from the selected tab's.
        let showBranch = branch != nil && branch != selectedBranch
        return Button {
            workspace.select(tab.id)
        } label: {
            HStack(spacing: SoraTheme.space2) {
                Image(systemName: tab.hasAgentActivity ? "sparkles" : "terminal")
                    .font(SoraTheme.chromeIcon)
                    .foregroundStyle(tab.hasAgentActivity ? SoraTheme.accent : SoraTheme.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle)
                        .font(SoraTheme.chromeBody)
                        .foregroundStyle(SoraTheme.text)
                        .lineLimit(1)
                    if showBranch, let branch {
                        Text(branch)
                            .font(SoraTheme.chromeCaption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SoraTheme.space2)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: SoraTheme.radiusSmall, style: .continuous)
                    .fill(selected ? SoraTheme.fillSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SoraChromeButtonStyle(fill: .clear, cornerRadius: SoraTheme.radiusSmall))
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
