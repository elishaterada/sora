import SwiftUI

struct WorkspaceCommands: Commands {
    @ObservedObject var shortcuts: AppShortcutStore
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var focusedWorkspace: WorkspaceController?
    // AppKit utility windows do not clear SwiftUI's last focused object.
    // Resolve ownership when an action runs so it cannot mutate a hidden tab.
    private var workspace: WorkspaceController? { focusedWorkspace?.ownsKeyWindow == true ? focusedWorkspace : nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "terminal", value: UUID()) }
                .appShortcut(.newWindow, store: shortcuts)
            Button("New Tab") {
                workspace?.addTabInheritingCWD()
            }
            .appShortcut(.newTab, store: shortcuts)
            .disabled(workspace == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let workspace { workspace.closeSelectedTab() }
                else { NSApp.keyWindow?.performClose(nil) }
            }
            .appShortcut(.closeTab, store: shortcuts)
            .disabled(NSApp.keyWindow == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Ask Agent About Selected Output…") {
                if let workspace { workspace.surface(for: workspace.selectedID).askAboutOutput(nil) }
            }
            .disabled(workspace == nil)
            Button("Search Command History…") {
                if let workspace { workspace.surface(for: workspace.selectedID).showHistorySearch() }
            }
            .disabled(workspace == nil)
            Button("Show Command Completions") {
                if let workspace { workspace.surface(for: workspace.selectedID).showCommandCompletions() }
            }
            .disabled(workspace == nil)
            Button("Accept Next Completion Word") {
                if let workspace { workspace.surface(for: workspace.selectedID).acceptNextCompletionWord() }
            }
            .disabled(workspace == nil)
            Button("Find in Terminal Output…") { workspace?.findOutput() }
                .appShortcut(.findOutput, store: shortcuts)
                .disabled(workspace == nil)
            Button("Find in Selected Block…") {
                if let workspace { workspace.surface(for: workspace.selectedID).showFind(scope: .selectedBlock) }
            }
            .disabled(workspace == nil || workspace.map { !$0.surface(for: $0.selectedID).isBrowsingCommandBlocks } == true)
        }
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { workspace?.showCommandPalette() }
                .appShortcut(.commandPalette, store: shortcuts)
                .disabled(workspace == nil)
        }
        CommandGroup(after: .help) {
            Button("Shell Integration…") { openWindow(id: "shell-integration") }
        }
        CommandMenu("Tabs") {
            Button("Split Terminal Side by Side") { workspace?.splitTerminal() }
                .appShortcut(.splitRight, store: shortcuts)
                .disabled(workspace?.canSplit(.right) != true)
            Button("Split Terminal Below") { workspace?.splitTerminal(axis: .below) }
                .appShortcut(.splitBelow, store: shortcuts)
                .disabled(workspace?.canSplit(.below) != true)
            Button(workspace?.isPaneMaximized == true ? "Restore Pane Layout" : "Maximize Pane") { workspace?.togglePaneMaximized() }
                .appShortcut(.maximizePane, store: shortcuts)
                .disabled(workspace?.hasSelectedSplit != true)
            Button("Focus Pane Left") { workspace?.focusPane(.left) }
                .appShortcut(.focusPaneLeft, store: shortcuts).disabled(workspace?.hasSelectedSplit != true)
            Button("Focus Pane Right") { workspace?.focusPane(.right) }
                .appShortcut(.focusPaneRight, store: shortcuts).disabled(workspace?.hasSelectedSplit != true)
            Button("Focus Pane Above") { workspace?.focusPane(.up) }
                .appShortcut(.focusPaneUp, store: shortcuts).disabled(workspace?.hasSelectedSplit != true)
            Button("Focus Pane Below") { workspace?.focusPane(.down) }
                .appShortcut(.focusPaneDown, store: shortcuts).disabled(workspace?.hasSelectedSplit != true)
            Button("Return to Single Pane") { workspace?.endSplit() }
                .appShortcut(.singlePane, store: shortcuts)
                .disabled(workspace?.hasSelectedSplit != true)
            Divider()
            Button("Rename Tab…") { if let id = workspace?.selectedID { workspace?.renameTab(id) } }
                .appShortcut(.renameTab, store: shortcuts)
                .disabled(workspace == nil)
            Button("Move Tab Up") { if let id = workspace?.selectedID { workspace?.moveTab(id, by: -1) } }
                .appShortcut(.moveTabUp, store: shortcuts)
                .disabled(workspace == nil || workspace?.selectedID == workspace?.tabs.first?.id)
            Button("Move Tab Down") { if let id = workspace?.selectedID { workspace?.moveTab(id, by: 1) } }
                .appShortcut(.moveTabDown, store: shortcuts)
                .disabled(workspace == nil || workspace?.selectedID == workspace?.tabs.last?.id)
            Button("Reopen Closed Tab") { workspace?.reopenTab() }
                .appShortcut(.reopenTab, store: shortcuts)
                .disabled(workspace?.canReopenTab != true)
            Divider()
            Button("Show Next Tab") {
                workspace?.selectNext()
            }
            .appShortcut(.nextTab, store: shortcuts)
            .disabled(workspace == nil)
            Button("Show Previous Tab") {
                workspace?.selectPrevious()
            }
            .appShortcut(.previousTab, store: shortcuts)
            .disabled(workspace == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") {
                    workspace?.gotoTab(Int32(number))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(workspace == nil)
            }
        }
    }
}
