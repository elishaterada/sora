import SwiftUI

struct WorkspaceCommands: Commands {
    @FocusedObject private var workspace: WorkspaceController?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                workspace?.addTabInheritingCWD()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(workspace == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                workspace?.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(workspace == nil)
        }
        CommandMenu("Tabs") {
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
