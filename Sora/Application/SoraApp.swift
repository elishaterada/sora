import SwiftUI

@main
struct SoraApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) private var appDelegate
    @StateObject private var runtime: GhosttyRuntime
    @StateObject private var ask = AskSession(backends: AIBackend.live())
    private let updates = UpdateController()

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
        WindowGroup("Sora", id: "terminal", for: UUID.self) { $windowID in
            ContentView(runtime: runtime, windowID: windowID ?? runtime.initialWindowID)
                .task { updates.checkAtLaunch() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in ask.stop() }
        } defaultValue: { runtime.initialWindowID }
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommands()
            SidebarCommands()
            HistoryCommands()
            AskCommands()
            UpdateCommands(updates: updates)
            // Standard Edit commands follow the first responder, including
            // SecureField and the Ask composer. GhosttySurfaceView implements
            // the same copy/paste/selectAll actions for terminal focus.
        }

        Window("History", id: "command-history") {
            CommandHistoryView(store: runtime.history)
        }
        .defaultSize(width: 520, height: 360)

        Settings {
            SoraSettingsView(session: ask)
        }
    }
}

private struct UpdateCommands: Commands {
    let updates: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
        }
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
        CommandMenu("Agent") {
            Button("Open Agent") { inlineAskAction?.call() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(inlineAskAction == nil)
        }
    }
}


private final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        func busy(_ view: NSView) -> Bool {
            if let terminal = view as? GhosttySurfaceView, terminal.hasRunningTask { return true }
            if let pane = view as? TerminalPaneView, pane.hasRunningAgent { return true }
            return view.subviews.contains(where: busy)
        }
        guard sender.windows.contains(where: { $0.contentView.map(busy) ?? false }) else {
            NotificationCenter.default.post(name: WorkspaceWindowStore.terminationApproved, object: nil)
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit with running tasks?"
        alert.informativeText = "Quitting will stop terminal commands and Agent requests. Your output history will be saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Sora")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        NotificationCenter.default.post(name: WorkspaceWindowStore.terminationApproved, object: nil)
        return .terminateNow
    }
}
