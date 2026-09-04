import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceController

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.tabs) { tab in
                        tabButton(tab)
                    }
                }
            }
            Button {
                workspace.addTabInheritingCWD()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New Tab")
        }
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabButton(_ tab: WorkspaceModel.Tab) -> some View {
        let selected = tab.id == workspace.selectedID
        return HStack(spacing: 6) {
            Button {
                workspace.select(tab.id)
            } label: {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .font(.system(size: 12))
                    .frame(minWidth: 72, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                workspace.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Close Tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(selected ? Color.accentColor : Color.clear),
            alignment: .bottom
        )
    }
}
