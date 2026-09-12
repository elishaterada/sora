import AppKit

/// A normal read-only output library. Its content is text, never a terminal
/// replay or executable command. Only the selected copy is loaded into memory.
final class BlockBookmarkLibrary: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: BlockBookmarkStore
    private let panel = BookmarkLibraryWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let output = NSTextView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [BlockBookmark] = []
    private var selected: BlockBookmark? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var copyButton: NSButton!
    private var sourceButton: NSButton!
    private var deleteButton: NSButton!

    init(store: BlockBookmarkStore) {
        self.store = store
        super.init()
        panel.title = "Block Bookmarks"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 720, height: 400)
        panel.setFrameAutosaveName("sora.blockBookmarks.window")
        let root = NSView()
        panel.contentView = root
        search.placeholderString = "Find bookmarks by command or folder"
        search.setAccessibilityLabel("Search block bookmarks")
        search.delegate = self
        panel.onFind = { [weak self] in guard let self else { return }; self.panel.makeFirstResponder(self.search) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Saved command blocks")
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.documentView = table
        list.borderType = .bezelBorder
        output.isEditable = false
        output.isSelectable = true
        output.isRichText = false
        output.isAutomaticLinkDetectionEnabled = false
        output.isAutomaticDataDetectionEnabled = false
        output.font = SoraTheme.terminalFont
        output.textColor = .textColor
        output.backgroundColor = .textBackgroundColor
        output.textContainerInset = NSSize(width: 12, height: 12)
        output.autoresizingMask = [.width]
        output.isVerticallyResizable = true
        output.isHorizontallyResizable = false
        output.textContainer?.widthTracksTextView = true
        output.setAccessibilityLabel("Bookmarked output, read only")
        let reader = NSScrollView()
        reader.hasVerticalScroller = true
        reader.documentView = output
        reader.borderType = .bezelBorder
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        sourceButton = NSButton(title: "Show Source Tab", target: self, action: #selector(showSource))
        copyButton = NSButton(title: "Copy Saved Output", target: self, action: #selector(copyOutput))
        deleteButton = NSButton(title: "Delete…", target: self, action: #selector(deleteSelected))
        let actions = NSStackView(views: [refresh, sourceButton, copyButton, deleteButton])
        actions.spacing = 8
        for view in [search, list, detail, reader, status, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: search.leadingAnchor), list.widthAnchor.constraint(equalToConstant: 270),
            list.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: list.topAnchor), detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 14),
            detail.trailingAnchor.constraint(equalTo: search.trailingAnchor), detail.heightAnchor.constraint(equalToConstant: 44),
            reader.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
            reader.leadingAnchor.constraint(equalTo: detail.leadingAnchor), reader.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            reader.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: search.leadingAnchor), status.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: 34),
            actions.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            actions.leadingAnchor.constraint(equalTo: search.leadingAnchor), actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }
    func show(select id: UUID? = nil) {
        if id != nil { search.stringValue = "" }
        store.refresh()
        reload(select: id ?? selected?.id)
        output.font = SoraTheme.terminalFont
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bookmark = rows[row]
        let label = NSTextField(wrappingLabelWithString: bookmark.command.replacingOccurrences(of: "\n", with: " ↵ ") + "\n" + bookmark.directory)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    func controlTextDidChange(_ obj: Notification) { reload(select: selected?.id) }
    private func reload(select id: UUID?) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = store.bookmarks.filter { query.isEmpty || ($0.command + " " + $0.directory).localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let id, let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        showSelection()
    }
    private func showSelection() {
        copyButton.isEnabled = selected != nil
        sourceButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
        status.stringValue = store.errorMessage ?? "Saved copies stay available until you delete them, even after their source tabs close."
        guard let selected else {
            output.string = ""
            detail.stringValue = rows.isEmpty
                ? (store.bookmarks.isEmpty ? "No bookmarks. Choose Bookmark Block from a command block’s actions." : "No matching bookmarks. Clear the search to see your saved blocks.")
                : "Select a saved block to read its output."
            return
        }
        do {
            output.string = try store.output(for: selected.id)
            output.scrollToBeginningOfDocument(nil)
            detail.stringValue = "Saved \(selected.createdAt.formatted(date: .abbreviated, time: .shortened)) · Tab folder: \(selected.directory)"
                + (selected.isExcerpt ? "\nExcerpt: first 1 MB of output. Later output is not included." : "\nSaved copy of the block’s output at capture time.")
        } catch { output.string = ""; status.stringValue = error.localizedDescription; copyButton.isEnabled = false }
    }
    @objc private func refresh() { store.refresh(); reload(select: selected?.id) }
    @objc private func copyOutput() { GhosttyClipboard.writePlainText(output.string, to: .general) }
    @objc private func showSource() {
        guard let selected else { return }
        func find(in view: NSView) -> GhosttySurfaceView? {
            if let surface = view as? GhosttySurfaceView, surface.tabID == selected.sourceTabID { return surface }
            for child in view.subviews { if let surface = find(in: child) { return surface } }
            return nil
        }
        for window in NSApp.windows {
            if let root = window.contentView, let surface = find(in: root) { surface.onNotificationActivate?(); return }
        }
        status.stringValue = "The source tab is closed. Its saved output is still available here."
    }
    @objc private func deleteSelected() {
        guard let selected else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this bookmarked block?"
        alert.informativeText = "This removes its saved copy. The source terminal and its history remain available."
        alert.addButton(withTitle: "Delete Bookmark")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.delete(selected.id); reload(select: nil) }
        catch { status.stringValue = error.localizedDescription }
    }
}

private final class BookmarkLibraryWindow: NSWindow {
    var onFind: (() -> Void)?
    private var keyMonitor: Any?
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self else { return event }
                return self.handleLibraryKey(event) ? nil : event
            }
        }
    }
    override func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        super.close()
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleLibraryKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    private func handleLibraryKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" { close(); return true }
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "f" { onFind?(); return true }
        if mods.isEmpty, event.keyCode == 53 { close(); return true }
        return false
    }
    override func cancelOperation(_ sender: Any?) { close() }
}
