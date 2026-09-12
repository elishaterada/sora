import AppKit

/// A separate input surface: searching never sends keystrokes to the shell.
final class CommandHistorySearchController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: CommandHistoryStore
    private let tabID: UUID
    private let directory: URL
    private let search = NSSearchField()
    private let scopes = NSSegmentedControl(labels: CommandHistoryScope.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "Searching…")
    private let saveButton = NSButton(title: "Save Command…", target: nil, action: nil)
    private let insertButton = NSButton(title: "Insert Command", target: nil, action: nil)
    private let worker = DispatchQueue(label: "dev.sora.history-search", qos: .userInitiated)
    private var pending: DispatchWorkItem?
    private var revision = UUID()
    private var results: [CommandHistorySearchHit] = []
    private var finished = false
    var onFinish: ((String?) -> Void)?

    init(store: CommandHistoryStore, tabID: UUID, directory: URL) {
        self.store = store
        self.tabID = tabID
        self.directory = directory
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Search Command History"
        super.init(window: panel)
        buildContent()
    }
    required init?(coder: NSCoder) { nil }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(search)
        refresh()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search words or characters anywhere in a command"
        search.setAccessibilityLabel("Search command history")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        scopes.selectedSegment = CommandHistoryScope.tab.rawValue
        scopes.target = self
        scopes.action = #selector(scopeChanged)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")))
        table.headerView = nil
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(insertSelected)
        table.setAccessibilityLabel("Matching commands")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSearch))
        cancel.keyEquivalent = "\u{1b}"
        insertButton.target = self
        insertButton.action = #selector(insertSelected)
        insertButton.keyEquivalent = "\r"
        insertButton.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let hint = NSTextField(labelWithString: "↑ ↓ select · Return inserts for editing · Escape keeps your draft")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        saveButton.target = self
        saveButton.action = #selector(saveSelected)
        saveButton.isEnabled = false
        let footer = NSStackView(views: [status, NSView(), saveButton, cancel, insertButton])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [search, scopes, scroll, hint, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }
    @objc private func scopeChanged() { refresh() }

    private func refresh() {
        pending?.cancel()
        let token = UUID()
        revision = token
        let query = String(search.stringValue.prefix(256))
        if query != search.stringValue { search.stringValue = query }
        let scope = CommandHistoryScope(rawValue: scopes.selectedSegment) ?? .tab
        status.stringValue = "Searching…"
        results = []
        table.reloadData()
        insertButton.isEnabled = false
        saveButton.isEnabled = false
        let work = DispatchWorkItem { [weak self, store, tabID, directory] in
            let result = Result { try store.search(query: query, scope: scope, tabID: tabID, directory: directory) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == token, !self.finished else { return }
                switch result {
                case .success(let matches):
                    self.results = matches
                    self.status.stringValue = matches.isEmpty ? "No matching commands" : "\(matches.count) best matches"
                case .failure(let error):
                    self.results = []
                    self.status.stringValue = "History could not be searched: \(error.localizedDescription)"
                }
                self.table.reloadData()
                self.table.selectRowIndexes(self.results.isEmpty ? [] : IndexSet(integer: 0), byExtendingSelection: false)
                self.insertButton.isEnabled = !self.results.isEmpty
                self.saveButton.isEnabled = !self.results.isEmpty
            }
        }
        pending = work
        worker.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(results.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)): insertSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelSearch(); return true
        default: return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        insertButton.isEnabled = results.indices.contains(table.selectedRow)
        saveButton.isEnabled = insertButton.isEnabled
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = results[row]
        let command = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(string: hit.command, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        for range in hit.match.ranges {
            text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        command.attributedStringValue = text
        command.lineBreakMode = .byTruncatingTail
        command.maximumNumberOfLines = 1
        command.toolTip = hit.command
        let metadata = NSTextField(labelWithString: "\(hit.directory)  ·  \(hit.lastUsed.formatted(date: .abbreviated, time: .shortened))  ·  \(hit.uses) use\(hit.uses == 1 ? "" : "s")")
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [command, metadata])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 3
        command.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        metadata.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        return cell
    }

    @objc private func saveSelected() {
        guard results.indices.contains(table.selectedRow) else { return }
        let hit = results[table.selectedRow]
        SavedCommandEditor.present(command: hit.command, directory: URL(fileURLWithPath: hit.directory), in: window)
    }

    @objc private func insertSelected() {
        guard insertButton.isEnabled, results.indices.contains(table.selectedRow) else { return }
        finish(results[table.selectedRow].command)
    }
    @objc private func cancelSearch() { finish(nil) }
    private func finish(_ command: String?) {
        guard !finished else { return }
        finished = true
        pending?.cancel()
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        onFinish?(command)
    }
}
