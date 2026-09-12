import SwiftUI

struct SidebarToggleButton: View {
    @Binding var sidebarVisible: Bool

    var body: some View {
        Button {
            withAnimation(SoraTheme.motionSidebar) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(SoraTheme.chromeBody)
                .foregroundStyle(SoraTheme.muted)
                .frame(width: SoraTheme.hitCompact, height: SoraTheme.hitCompact)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoraChromeButtonStyle())
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }
}

/// Thin content header. When the sidebar is gone, traffic lights and the
/// sidebar toggle live here, beside session identity. Each pane owns its path
/// and branch controls in the terminal input or Agent status bar.
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

            Spacer(minLength: SoraTheme.space2)

            agentButton

            if !sidebarVisible {
                newTabButton
            }
        }
        .padding(.leading, sidebarVisible ? SoraTheme.space3 : 0)
        .padding(.trailing, 10)
        .frame(height: titlebarHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SoraTheme.hairline)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var sessionTitle: some View {
        let title = workspace.selected.displayTitle
        if sidebarVisible || workspace.tabs.count == 1 {
            titleLabel(title: title)
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
                titleLabel(title: title)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Switch Tab")
        }
    }

    private func titleLabel(title: String) -> some View {
        Text(title)
            .font(SoraTheme.chromeBody)
            .foregroundStyle(SoraTheme.text)
            .lineLimit(1)
    }

    private var agentButton: some View {
        Button(action: onAsk) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                Text("Agent")
                    .font(SoraTheme.chromeCaptionSemibold)
            }
            .foregroundStyle(SoraTheme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(SoraTheme.accent.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(SoraTheme.accent.opacity(0.32), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SoraChromeButtonStyle(
            fill: .clear,
            pressedFill: SoraTheme.accent.opacity(0.16),
            hoverFill: SoraTheme.accent.opacity(0.10),
            cornerRadius: 5
        ))
        .help("Open Agent (" + workspace.runtime.shortcuts.binding(.openAgent).display + ")")
        .accessibilityLabel("Open Agent")
    }

    private var newTabButton: some View {
        Button {
            workspace.addTabInheritingCWD()
        } label: {
            Image(systemName: "plus")
                .font(SoraTheme.chromeBody)
                .foregroundStyle(SoraTheme.muted)
                .frame(width: SoraTheme.hitCompact, height: SoraTheme.hitCompact)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoraChromeButtonStyle())
        .help("New Tab")
        .accessibilityLabel("New Tab")
    }
}
