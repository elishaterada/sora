import AppKit

/// Uses the real menu items so the palette follows menu validation and shortcuts.
final class CommandPaletteController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        let title: String
        let detail: String
        let shortcut: String
        let enabled: Bool
        let perform: () -> Void
    }
    private struct Match { let entry: Entry; let highlight: FuzzySearchMatch }
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let choose = NSButton(title: "Choose", target: nil, action: nil)
    private var entries: [Entry] = []
    private var matches: [Match] = []
    private weak var previousResponder: NSResponder?
    var onClose: (() -> Void)?

    init(workspace: WorkspaceController) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Command Palette"
        super.init(window: panel)
        if let menu = NSApp.mainMenu { collect(menu, path: []) }
        for tab in workspace.tabs {
            entries.append(Entry(title: tab.displayTitle, detail: "Session · \(tab.workingDirectory?.path ?? "Home folder")", shortcut: "", enabled: true) {
                workspace.select(tab.id)
            })
        }
        let surface = workspace.surface(for: workspace.selectedID)
        do {
            for program in try AgentProgramStore.standard.load() {
                entries.append(Entry(title: program.name, detail: "Saved command · Insert for editing · \(program.directory)", shortcut: "", enabled: surface.canInsertCommandForEditing) { [weak surface] in
                    surface?.insertCommandForEditing(program.script)
                })
            }
        } catch {
            entries.append(Entry(title: "Saved commands unavailable", detail: error.localizedDescription, shortcut: "", enabled: false, perform: {}))
        }
        buildContent()
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    func present(in parent: NSWindow) {
        guard let window else { return }
        previousResponder = parent.firstResponder
        parent.beginSheet(window)
        window.makeFirstResponder(search)
    }

    private func collect(_ menu: NSMenu, path: [String]) {
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                // Services can contain expensive, dynamically populated external menus.
                if submenu !== NSApp.servicesMenu { collect(submenu, path: path + [item.title]) }
            } else if item.action != nil, !item.title.isEmpty, item.title != "Command Palette…" {
                let shortcut = Self.shortcut(item)
                entries.append(Entry(title: item.title, detail: path.joined(separator: " › "), shortcut: shortcut, enabled: item.isEnabled) { [weak item] in
                    guard let item else { return }
                    item.menu?.update()
                    guard item.isEnabled, let action = item.action else { NSSound.beep(); return }
                    NSApp.sendAction(action, to: item.target, from: item)
                })
            }
        }
    }
    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var result = ""
        for (flag, text): (NSEvent.ModifierFlags, String) in [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
            if item.keyEquivalentModifierMask.contains(flag) { result += text }
        }
        let symbols = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
                       "\t": "⇥", "\r": "↩", "\u{1b}": "⎋", "\u{7f}": "⌫"]
        return result + (symbols[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search actions, sessions, settings, and saved commands"
        search.setAccessibilityLabel("Search command palette")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action")))
        table.headerView = nil
        table.rowHeight = 48
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(accept)
        table.setAccessibilityLabel("Commands and sessions")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPalette))
        cancel.keyEquivalent = "\u{1b}"
        choose.target = self
        choose.action = #selector(accept)
        choose.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [status, NSView(), cancel, choose])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [search, scroll, footer])
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    private func refresh() {
        let query = String(search.stringValue.prefix(256))
        matches = entries.compactMap { entry in
            guard let match = FuzzySearch.match(query, in: entry.title) ?? FuzzySearch.match(query, in: entry.detail + " " + entry.shortcut) else { return nil }
            return Match(entry: entry, highlight: match)
        }.sorted {
            if $0.highlight.score != $1.highlight.score { return $0.highlight.score > $1.highlight.score }
            if $0.entry.enabled != $1.entry.enabled { return $0.entry.enabled }
            return $0.entry.title.localizedStandardCompare($1.entry.title) == .orderedAscending
        }
        table.reloadData()
        table.selectRowIndexes(matches.isEmpty ? [] : IndexSet(integer: 0), byExtendingSelection: false)
        updateSelection()
    }
    private func updateSelection() {
        choose.isEnabled = matches.indices.contains(table.selectedRow) && matches[table.selectedRow].entry.enabled
        status.stringValue = choose.isEnabled ? "↑ ↓ select · Return choose · Escape dismiss" : (matches.isEmpty ? "No matching commands" : "Unavailable in the current context")
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !matches.isEmpty else { return true }
            let row = min(matches.count - 1, max(0, table.selectedRow + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)): accept(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelPalette(); return true
        default: return false
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = matches[row].entry
        let title = NSTextField(labelWithString: entry.title + (entry.shortcut.isEmpty ? "" : "    " + entry.shortcut))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = entry.enabled ? .labelColor : .disabledControlTextColor
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: entry.detail + (entry.enabled ? "" : " · Unavailable"))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [title, detail])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 3
        title.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        return cell
    }
    @objc private func accept() {
        guard choose.isEnabled, matches.indices.contains(table.selectedRow) else { return }
        let action = matches[table.selectedRow].entry.perform
        dismiss()
        DispatchQueue.main.async(execute: action)
    }
    @objc private func cancelPalette() { dismiss() }
    private func dismiss() {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
            window.orderOut(nil)
            parent.makeFirstResponder(previousResponder)
        }
        onClose?()
    }
}
