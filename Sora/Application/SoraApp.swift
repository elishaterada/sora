import SwiftUI

@main
struct SoraApp: App {
    @StateObject private var runtime: GhosttyRuntime

    init() {
        do {
            let history = try CommandHistoryStore()
            try HushLogin.ensure()
            _ = try SoraZshBootstrap.prepare()
            // App-scoped: do not change the user's global Tahoe defaults.
            UserDefaults.standard.set(false, forKey: "NSSplitViewItemSidebarDefaultsToFloatingAppearance")
            let runtime = try GhosttyRuntime(history: history)
            _runtime = StateObject(wrappedValue: runtime)
        } catch {
            fatalError("Ghostty runtime failed to start: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(runtime: runtime)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommands()
            SidebarCommands()
            HistoryCommands()
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { runtime.copyFromActiveSurface() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { runtime.pasteIntoActiveSurface() }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Select All") { runtime.selectAllOnActiveSurface() }
                    .keyboardShortcut("a", modifiers: .command)
            }
        }

        Window("History", id: "command-history") {
            CommandHistoryView(store: runtime.history)
        }
        .defaultSize(width: 520, height: 360)
    }
}

private struct HistoryCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("Command History") {
                openWindow(id: "command-history")
            }
        }
    }
}
