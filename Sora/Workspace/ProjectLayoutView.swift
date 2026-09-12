import AppKit
import SwiftUI

struct ProjectLayoutCommands: Commands {
    @ObservedObject var runtime: GhosttyRuntime
    @ObservedObject var store: ProjectLayoutStore
    @FocusedObject private var focusedWorkspace: WorkspaceController?
    private var workspace: WorkspaceController? { focusedWorkspace?.ownsKeyWindow == true ? focusedWorkspace : nil }
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Save Project Layout…") { if let workspace { ProjectLayoutActions.save(workspace: workspace, store: store) } }
                .disabled(workspace == nil)
            Menu("Open Project Layout") {
                if store.layouts.isEmpty { Text("No Saved Layouts") }
                ForEach(store.layouts) { layout in
                    Button(layout.name) { ProjectLayoutActions.open(layout, runtime: runtime, store: store, openWindow: openWindow) }
                }
            }
            Button("Manage Project Layouts…") { store.refresh(); openWindow(id: "project-layouts") }
        }
    }
}

struct ProjectLayoutsView: View {
    @ObservedObject var runtime: GhosttyRuntime
    @ObservedObject var store: ProjectLayoutStore
    @AppStorage(TerminalPreferences.appearanceKey) private var appearanceName = "dark"
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: UUID?
    private var selected: ProjectLayout? { store.layouts.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a saved arrangement as new terminal sessions.").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                List(store.layouts, selection: $selectedID) { layout in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layout.name).font(.headline)
                        Text("\(layout.tabs.count) tabs" + (layout.hasSplit ? " · Split panes" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(layout.id)
                }.frame(minWidth: 210, maxWidth: 250)
                if let selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(selected.name).font(.title3.bold())
                            ForEach(Array(selected.tabs.enumerated()), id: \.offset) { index, tab in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.name.isEmpty ? "Tab \(index + 1)" : tab.name).font(.headline)
                                    Text(tab.directory.isEmpty ? "Home folder" : tab.directory)
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(store.layouts.isEmpty ? "Save the current window from File → Save Project Layout." : "Select a layout to review its folders.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(SoraTheme.danger) }
            if let message = store.recoveryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Refresh") { store.refresh() }
                Button("Show Saved Data") { NSWorkspace.shared.selectFile(store.url.path, inFileViewerRootedAtPath: "") }
                Spacer()
                Button("Rename…") { if let selected { ProjectLayoutActions.rename(selected, store: store) } }.disabled(selected == nil)
                Button("Delete…") { if let selected { ProjectLayoutActions.delete(selected, store: store) } }.disabled(selected == nil)
                Button("Open Layout") {
                    if let selected { ProjectLayoutActions.open(selected, runtime: runtime, store: store, openWindow: openWindow) }
                }.disabled(selected == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(minWidth: 700, minHeight: 400)
        .preferredColorScheme(TerminalPreferences.Appearance(rawValue: appearanceName)?.colorScheme)
        .onAppear { store.refresh() }
    }
}

enum ProjectLayoutActions {
    static func save(workspace: WorkspaceController, store: ProjectLayoutStore) {
        let snapshot = workspace.projectLayoutSnapshot()
        editName(title: "Save Project Layout", initial: workspace.selected.workingDirectory?.lastPathComponent ?? "Project",
            detail: "Save this window’s tab names, folders and pane arrangement. Reopening creates new sessions without replaying commands or drafts.") { name in
            _ = try store.save(name: name, snapshot: snapshot)
        }
    }
    static func rename(_ layout: ProjectLayout, store: ProjectLayoutStore) {
        editName(title: "Rename Project Layout", initial: layout.name, detail: "Choose a name for this saved arrangement.") {
            try store.rename(layout, to: $0)
        }
    }
    private static func editName(title: String, initial: String, detail: String, save: (String) throws -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.setAccessibilityLabel("Layout name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            do { try save(field.stringValue); return }
            catch { alert.informativeText = error.localizedDescription }
        }
    }
    static func delete(_ layout: ProjectLayout, store: ProjectLayoutStore) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(layout.name)”?"
        alert.informativeText = "This removes the saved layout. Open terminals and their history remain available."
        alert.addButton(withTitle: "Delete Layout")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.delete(layout) } catch { show(error) }
    }
    static func open(_ layout: ProjectLayout, runtime: GhosttyRuntime, store: ProjectLayoutStore, openWindow: OpenWindowAction) {
        do {
            let current = try store.current(layout.id)
            guard let snapshot = try resolveFolders(current) else { return }
            let id = UUID()
            guard runtime.windowStore.save(snapshot, for: id) else {
                throw NSError(domain: "Sora.Layout", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    runtime.windowStore.persistenceError ?? "Could not save the new workspace. The layout was not opened."])
            }
            openWindow(id: "terminal", value: id)
        } catch { show(error) }
    }
    private static func resolveFolders(_ layout: ProjectLayout) throws -> WorkspaceSnapshot? {
        let missing = layout.missingFolders()
        guard !missing.isEmpty else { return try layout.snapshot() }
        let paths = Array(Set(missing.map { layout.tabs[$0].directory })).sorted()
        let alert = NSAlert()
        alert.messageText = "Some folders in “\(layout.name)” are unavailable"
        alert.informativeText = paths.joined(separator: "\n") + "\n\nChoose replacements, open those tabs in your home folder, or cancel. This opening will not change the saved layout."
        alert.addButton(withTitle: "Choose Folders…")
        alert.addButton(withTitle: "Use Home Folder")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return nil }
        var replacements: [Int: URL] = [:]
        for path in paths {
            let replacement: URL
            if choice == .alertSecondButtonReturn { replacement = FileManager.default.homeDirectoryForCurrentUser }
            else {
                let panel = NSOpenPanel()
                panel.title = "Choose Replacement Folder"
                panel.message = "Replace \(path) for this opening."
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return nil }
                replacement = url
            }
            for index in missing where layout.tabs[index].directory == path { replacements[index] = replacement }
        }
        return try layout.snapshot(replacements: replacements)
    }
    private static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not update project layouts"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
