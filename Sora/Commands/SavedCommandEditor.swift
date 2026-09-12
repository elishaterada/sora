import AppKit

/// A local save dialog shared by terminal blocks and history. It never executes
/// a command, changes the working directory, or starts an Agent request.
enum SavedCommandEditor {
    static func present(command: String, directory: URL, in parent: NSWindow?) {
        let previousResponder = parent?.firstResponder
        let alert = NSAlert()
        alert.messageText = "Save Command"
        alert.informativeText = "Give this command a name to find it in the command palette. Reusing it inserts it into your current session for editing."
        alert.addButton(withTitle: "Save Command")
        alert.addButton(withTitle: "Cancel")

        var suggested = command.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        while suggested.utf8.count > 100 { suggested.removeLast() }
        let name = NSTextField(string: suggested)
        name.placeholderString = "Command name"
        name.setAccessibilityLabel("Saved command name")
        let summary = NSTextField(string: "Saved terminal command")
        summary.placeholderString = "Description"
        summary.setAccessibilityLabel("Saved command description")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
        editor.autoresizingMask = [.width]
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.string = command
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.setAccessibilityLabel("Command to save")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        let folder = NSTextField(labelWithString: "Saved folder: \(directory.path)")
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        let error = NSTextField(wrappingLabelWithString: "")
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [name, summary, scroll, folder, error])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: 290)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 480),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 160),
            folder.widthAnchor.constraint(equalTo: stack.widthAnchor),
            error.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        defer { parent?.makeFirstResponder(previousResponder) }
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                _ = try AgentProgramStore.standard.saveCommand(name: name.stringValue,
                    summary: summary.stringValue, script: editor.string, directory: directory)
                return
            } catch let failure {
                error.stringValue = failure.localizedDescription
                alert.layout()
            }
        }
    }
}
