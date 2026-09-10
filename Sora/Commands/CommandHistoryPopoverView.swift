import AppKit

/// An in-pane overlay, above the input. It never changes the terminal's size
/// and keeps keyboard events with the terminal responder while browsing.
final class CommandHistoryPopoverView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "History")
    private let countLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "↑ ↓ Navigate    Return Run    Tab Edit    Esc Cancel")
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let table = HistoryTableView()
    private var entries: [CommandHistoryEntry] = [] // oldest first on screen
    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private static let rowHeight: CGFloat = 30

    var preferredHeight: CGFloat { entries.isEmpty ? 120 : 68 + CGFloat(min(8, entries.count)) * Self.rowHeight }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 35.0 / 255, green: 38.0 / 255, blue: 43.0 / 255, alpha: 1).cgColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel history")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.toolTip = "Cancel history (Escape)"
        closeButton.setAccessibilityLabel("Cancel history")
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(choose)
        table.setAccessibilityLabel("Command history")
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        for view in [titleLabel, countLabel, scrollView, messageLabel, hintLabel, closeButton] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command history picker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ session: CommandHistorySession) {
        let updated = Array(session.entries.reversed())
        if entries != updated {
            entries = updated
            table.reloadData()
        }
        countLabel.stringValue = session.draft.isEmpty ? "Recent commands" : "Matching commands"
        if session.isLoading {
            messageLabel.stringValue = "Loading history…"
        } else if session.errorMessage != nil {
            messageLabel.stringValue = "Couldn’t load history. Press Escape, then ↑ to try again."
            messageLabel.toolTip = session.errorMessage
        } else {
            messageLabel.stringValue = session.draft.isEmpty
                ? "No command history yet. Run a command to see it here."
                : "No commands match this input. Press Escape to keep editing."
            messageLabel.toolTip = nil
        }
        scrollView.isHidden = entries.isEmpty
        messageLabel.isHidden = !entries.isEmpty
        if session.selected != nil {
            let row = entries.count - 1 - session.selectedIndex
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            revealSelectedRow()
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let geometry = CommandHistoryLayout(height: bounds.height)
        titleLabel.isHidden = geometry.header == 0
        countLabel.isHidden = geometry.header == 0
        closeButton.isHidden = geometry.header == 0
        titleLabel.frame = NSRect(x: 24, y: bounds.height - 27, width: 65, height: 17)
        countLabel.frame = NSRect(x: 93, y: bounds.height - 26, width: max(0, width - 145), height: 16)
        closeButton.frame = NSRect(x: max(0, width - 38), y: bounds.height - 30, width: 24, height: 24)
        scrollView.frame = NSRect(x: 12, y: geometry.footer, width: max(0, width - 24), height: geometry.rows)
        table.tableColumns.first?.width = scrollView.contentSize.width
        revealSelectedRow()
        messageLabel.frame = NSRect(x: 24, y: geometry.footer + 2, width: max(0, width - 48), height: max(0, geometry.rows - 4))
        hintLabel.stringValue = entries.isEmpty ? "Esc Cancel" : (width < 480
            ? "↑ ↓ Navigate   ↵ Run   Esc Cancel"
            : "↑ ↓ Navigate    Return Run    Tab Edit    Esc Cancel")
        hintLabel.isHidden = geometry.footer == 0
        hintLabel.frame = NSRect(x: 24, y: max(0, (geometry.footer - 16) / 2), width: max(0, width - 48), height: 16)
    }

    private func revealSelectedRow() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let clipView = scrollView.contentView
        let visible = clipView.documentVisibleRect
        guard visible.height > 0 else { return }
        let row = table.rect(ofRow: table.selectedRow)
        var bounds = clipView.bounds
        if row.minY < visible.minY {
            bounds.origin.y += row.minY - visible.minY
        } else if row.maxY > visible.maxY {
            bounds.origin.y += row.maxY - visible.maxY
        } else {
            return
        }
        // NSTableView.scrollRowToVisible animates long jumps. Position the clip
        // directly so opening history shows the latest command immediately.
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.12).setFill()
        let geometry = CommandHistoryLayout(height: bounds.height)
        for y in [CGFloat(0), geometry.footer, bounds.height - geometry.header, bounds.height - 1] {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("history-row")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HistoryRowView) ?? HistoryRowView()
        cell.identifier = id
        let entry = entries[row]
        cell.update(command: entry.command, time: dateFormatter.localizedString(for: entry.lastUsed, relativeTo: Date()))
        return cell
    }

    @objc private func choose() {
        guard entries.indices.contains(table.clickedRow) else { return }
        onChoose?(entries.count - 1 - table.clickedRow)
    }

    @objc private func dismiss() { onDismiss?() }
}

private final class HistoryTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

private final class HistoryRowView: NSTableCellView {
    private let commandLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        commandLabel.font = SoraTheme.terminalFont.withSize(16)
        commandLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        for view in [icon, commandLabel, timeLabel] { addSubview(view) }
        textField = commandLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(command: String, time: String) {
        commandLabel.stringValue = command.replacingOccurrences(of: "\n", with: " ↵ ")
        timeLabel.stringValue = time
        toolTip = command
        setAccessibilityLabel(command)
        setAccessibilityValue(time)
    }

    override func layout() {
        super.layout()
        let timeWidth: CGFloat = bounds.width >= 440 ? 110 : 0
        icon.frame = NSRect(x: 12, y: 8, width: 14, height: 14)
        commandLabel.frame = NSRect(x: 35, y: 4, width: max(0, bounds.width - 49 - timeWidth), height: 22)
        timeLabel.isHidden = timeWidth == 0
        timeLabel.frame = NSRect(x: bounds.width - timeWidth - 12, y: 7, width: timeWidth, height: 17)
    }
}
