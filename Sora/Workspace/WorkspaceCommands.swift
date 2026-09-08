import SwiftUI

struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var workspace: WorkspaceController?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "terminal", value: UUID()) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") {
                workspace?.addTabInheritingCWD()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workspace == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                workspace?.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(workspace == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Terminal Output…") { workspace?.findOutput() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace == nil)
        }
        CommandMenu("Tabs") {
            Button("Split Terminal Side by Side") { workspace?.splitTerminal() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(workspace == nil || workspace?.splitPair.isEmpty == false)
            Button("Return to Single Pane") { workspace?.endSplit() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace?.splitPair.isEmpty != false)
            Divider()
            Button("Rename Tab…") { if let id = workspace?.selectedID { workspace?.renameTab(id) } }
            Button("Reopen Closed Tab") { workspace?.reopenTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(workspace?.canReopenTab != true)
            Divider()
            Button("Show Next Tab") {
                workspace?.selectNext()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(workspace == nil)
            Button("Show Previous Tab") {
                workspace?.selectPrevious()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
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
