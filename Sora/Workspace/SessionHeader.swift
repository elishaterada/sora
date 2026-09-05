import SwiftUI

struct SessionHeader: View {
    let workingDirectory: URL?

    var body: some View {
        HStack(spacing: 6) {
            if let workingDirectory {
                ContextChip(
                    title: displayPath,
                    systemImage: "folder",
                    help: workingDirectory.path,
                    actions: ContextChipActions.path(workingDirectory)
                )
            } else {
                Label("~", systemImage: "folder")
            }
            if let branch, let root = workingDirectory.flatMap({ GitRepository.root(containing: $0) }) {
                ContextChip(
                    title: branch,
                    systemImage: "arrow.triangle.branch",
                    help: "Branch \(branch)",
                    actions: ContextChipActions.branch(branch, repositoryRoot: root)
                )
            } else if let branch {
                ContextChip(
                    title: branch,
                    systemImage: "arrow.triangle.branch",
                    help: "Branch \(branch)",
                    actions: ContextChipActions.branch(branch, repositoryRoot: nil)
                )
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    private var displayPath: String {
        StickyPromptBarModel.displayPath(for: workingDirectory)
    }

    private var branch: String? {
        GitRepository.branchName(containing: workingDirectory)
    }
}

struct SidebarToggleButton: View {
    @Binding var sidebarVisible: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }
}

/// Thin content header. When the sidebar is gone, traffic lights and the
/// sidebar toggle live here — same row as the session title and path.
struct TerminalChromeBar: View {
    @ObservedObject var workspace: WorkspaceController
    @Binding var sidebarVisible: Bool
    var titlebarHeight: CGFloat
    var trafficLightWidth: CGFloat
    var onAsk: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if !sidebarVisible {
                Color.clear
                    .frame(width: min(trafficLightWidth, 120), height: 1)
                SidebarToggleButton(sidebarVisible: $sidebarVisible)
            }

            sessionTitle

            Spacer(minLength: 8)

            agentButton

            SessionHeader(workingDirectory: workspace.selected.workingDirectory)

            if !sidebarVisible {
                newTabButton
            }
        }
        .padding(.leading, sidebarVisible ? 12 : 0)
        .padding(.trailing, 10)
        .frame(height: titlebarHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var sessionTitle: some View {
        let title = workspace.selected.displayTitle
        let branch = GitRepository.branchName(containing: workspace.selected.workingDirectory)
        if sidebarVisible || workspace.tabs.count == 1 {
            titleLabel(title: title, branch: branch)
        } else {
            Menu {
                ForEach(workspace.tabs) { tab in
                    Button {
                        workspace.select(tab.id)
                    } label: {
                        if tab.id == workspace.selectedID {
                            Label(tab.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(tab.displayTitle)
                        }
                    }
                }
            } label: {
                titleLabel(title: title, branch: branch)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Switch Tab")
        }
    }

    private func titleLabel(title: String, branch: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let branch {
                Text(branch)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var agentButton: some View {
        Button(action: onAsk) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Agent")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Agent (⌘⇧A)")
        .accessibilityLabel("Open Agent")
    }

    private var newTabButton: some View {
        Button {
            workspace.addTabInheritingCWD()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab")
        .accessibilityLabel("New Tab")
    }
}
