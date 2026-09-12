import SwiftUI

struct WorkspaceTabBar: View {
    @AppStorage(TerminalPreferences.compactSpacingKey) private var compact = false
    @ObservedObject var workspace: WorkspaceController
    @Binding var sidebarVisible: Bool
    var titlebarHeight: CGFloat
    var trafficLightWidth: CGFloat
    @State private var hoveredTab: UUID?
    @State private var dropTarget: UUID?
    @State private var draggedTab: UUID?
    @State private var rowBounds: [UUID: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero

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
                    .padding(.vertical, compact ? 4 : 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoraChromeButtonStyle())
            .help("New Tab")
            .padding(.horizontal, 6)
            .padding(.top, SoraTheme.space1)

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
            .coordinateSpace(name: "session-list")
            .background(GeometryReader { geometry in
                Color.clear.preference(key: SessionViewportSize.self, value: geometry.size)
            })
            .onPreferenceChange(SessionRowBounds.self) { rowBounds = $0 }
            .onPreferenceChange(SessionViewportSize.self) { viewportSize = $0 }

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
        let showBranch = branch != nil && branch != selectedBranch
        let activity = workspace.activities[tab.id]
        let agentBusy = workspace.busyAgents.contains(tab.id)
        let status = agentBusy ? "Agent running" : activity?.label ?? workspace.attention[tab.id]
        let color = activity?.isFailure == true && !agentBusy ? SoraTheme.danger : SoraTheme.accent
        return HStack(spacing: 0) {
            HStack(spacing: SoraTheme.space2) {
                    Image(systemName: agentBusy ? "sparkles" : activity?.symbol ?? (tab.hasAgentActivity ? "sparkles" : "terminal"))
                        .font(SoraTheme.chromeIcon)
                        .foregroundStyle(status == nil ? SoraTheme.muted : color)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.displayTitle).font(SoraTheme.chromeBody).foregroundStyle(SoraTheme.text).lineLimit(1)
                        if let status { Text(status).font(SoraTheme.chromeCaption).foregroundStyle(color) }
                        if showBranch, let branch {
                            Text(branch).font(SoraTheme.chromeCaption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, SoraTheme.space2)
                .padding(.vertical, compact ? 4 : 6)
                .contentShape(Rectangle())
            .onTapGesture(count: 2) { workspace.renameTab(tab.id) }
            .onTapGesture { workspace.select(tab.id) }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { workspace.select(tab.id) }
            .accessibilityLabel(tab.displayTitle + (status.map { ", " + $0 } ?? ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("session-list"))
                .onChanged { value in
                    draggedTab = tab.id
                    dropTarget = WorkspaceModel.dropTarget(at: value.location, rows: rowBounds, viewport: viewportSize)
                }
                .onEnded { value in
                    if let target = WorkspaceModel.dropTarget(at: value.location, rows: rowBounds, viewport: viewportSize) {
                        workspace.moveTab(tab.id, to: target)
                    }
                    draggedTab = nil
                    dropTarget = nil
                })
            Button { workspace.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .opacity(hoveredTab == tab.id || selected ? 1 : 0)
            .help("Close Tab (" + workspace.runtime.shortcuts.binding(.closeTab).display + ")")
            .accessibilityLabel("Close " + tab.displayTitle)
        }
        .background(RoundedRectangle(cornerRadius: SoraTheme.radiusSmall).fill(selected ? SoraTheme.fillSubtle : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: SoraTheme.radiusSmall).stroke(dropTarget == tab.id ? SoraTheme.accent : .clear, lineWidth: 1))
        .onHover { inside in
            if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil }
        }
        .opacity(draggedTab == tab.id ? 0.7 : 1)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: SessionRowBounds.self, value: [tab.id: geometry.frame(in: .named("session-list"))])
        })
        .contextMenu {
            Button("Rename Tab…") { workspace.renameTab(tab.id) }
            Button("Move Up") { workspace.moveTab(tab.id, by: -1) }.disabled(workspace.tabs.first?.id == tab.id)
            Button("Move Down") { workspace.moveTab(tab.id, by: 1) }.disabled(workspace.tabs.last?.id == tab.id)
            Divider()
            Button("Close Tab", role: .destructive) { workspace.closeTab(id: tab.id) }
        }
    }
}

private struct SessionRowBounds: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}
private struct SessionViewportSize: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { let next = nextValue(); if next.width > 0 && next.height > 0 { value = next } }
}
