import SwiftUI

@main
struct SoraApp: App {
    @StateObject private var runtime: GhosttyRuntime
    @StateObject private var ask = AskSession(backends: AIBackend.live())

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
            ContentView(runtime: runtime, ask: ask)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in ask.stop() }
        }
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommands()
            SidebarCommands()
            HistoryCommands()
            AskCommands()
            // Standard Edit commands follow the first responder, including
            // SecureField and the Ask composer. GhosttySurfaceView implements
            // the same copy/paste/selectAll actions for terminal focus.
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

private struct AskCommands: Commands {
    @FocusedValue(\.inlineAskAction) private var inlineAskAction

    var body: some Commands {
        CommandMenu("AI") {
            Button("Ask Sora") { inlineAskAction?.call() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(inlineAskAction == nil)
        }
    }
}
