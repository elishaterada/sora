import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceController
    @State private var hoveredID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SoraTheme.copper)
                Text("Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SoraTheme.muted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 8)

            Button {
                workspace.addTabInheritingCWD()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New Tab")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("⌘T")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SoraTheme.muted)
                }
                .foregroundStyle(SoraTheme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(SoraTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("New Tab")
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 216)
        .background(SoraTheme.sidebar)
    }

    private func tabButton(_ tab: WorkspaceModel.Tab) -> some View {
        let selected = tab.id == workspace.selectedID
        let hovered = hoveredID == tab.id
        return HStack(spacing: 8) {
            Button {
                workspace.select(tab.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? SoraTheme.copper : SoraTheme.muted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.displayTitle)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(SoraTheme.text)
                            .lineLimit(1)
                        if let branch = GitRepository.branchName(containing: tab.workingDirectory) {
                            Text(branch)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(SoraTheme.sage)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if workspace.tabs.count > 1, hovered || selected {
                Button {
                    workspace.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(SoraTheme.muted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? SoraTheme.surface : (hovered ? SoraTheme.surface.opacity(0.55) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? SoraTheme.copper.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            if hovering {
                hoveredID = tab.id
            } else if hoveredID == tab.id {
                hoveredID = nil
            }
        }
        .accessibilityLabel(tab.displayTitle)
    }
}
