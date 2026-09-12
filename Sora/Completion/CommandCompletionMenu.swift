import AppKit

/// A child window that keeps typing and keyboard focus in the terminal.
final class CommandCompletionMenu: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let footer = NSStackView()
    private var choices: [CommandCompletionChoice] = []
    private var observers: [NSObjectProtocol] = []
    var onChoose: ((CommandCompletionChoice) -> Void)?
    var onShellCompletion: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = "Command Completions"
        super.init(window: panel)
        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        panel.contentView = content
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion")))
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = .zero
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClicked)
        table.setAccessibilityLabel("Command completions")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: "↑ ↓ select · Tab / Return insert · Esc dismiss")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        let fallback = NSButton(title: "Shell completion", target: self, action: #selector(useShellCompletion))
        fallback.bezelStyle = .inline
        fallback.font = .systemFont(ofSize: 10)
        footer.addArrangedSubview(hint)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(fallback)
        footer.orientation = .horizontal
        footer.spacing = 8
        content.addSubview(scroll)
        content.addSubview(message)
        content.addSubview(footer)
    }
    required init?(coder: NSCoder) { nil }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func present(choices: [CommandCompletionChoice], error: String? = nil, above anchor: NSView) {
        guard let panel = window, let parent = anchor.window else { return }
        self.choices = choices
        let height = choices.isEmpty ? 132.0 : Double(min(8, choices.count) * 40 + 38)
        let width = 450.0
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = parent.screen?.visibleFrame ?? anchorRect.insetBy(dx: -600, dy: -600)
        let x = min(max(screen.minX + 8, anchorRect.minX), screen.maxX - width - 8)
        let y = min(max(screen.minY + 8, anchorRect.maxY + 4), screen.maxY - height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        scroll.frame = NSRect(x: 6, y: 32, width: width - 12, height: height - 38)
        message.frame = scroll.frame.insetBy(dx: 8, dy: 8)
        footer.frame = NSRect(x: 10, y: 3, width: width - 20, height: 26)
        table.tableColumns.first?.width = width - 24
        scroll.isHidden = choices.isEmpty
        message.isHidden = !choices.isEmpty
        message.stringValue = error ?? "No matching choices. Use shell completion for more options."
        table.reloadData()
        table.selectRowIndexes(choices.isEmpty ? [] : IndexSet(integer: 0), byExtendingSelection: false)
        panel.appearance = parent.appearance
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: nil) { [weak self] _ in self?.onCancel?() })
        }
    }

    func hide() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil) }
    }
    func move(_ offset: Int) {
        guard !choices.isEmpty else { return }
        let row = min(choices.count - 1, max(0, table.selectedRow + offset))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    func accept() { if choices.indices.contains(table.selectedRow) { onChoose?(choices[table.selectedRow]) } }
    @objc private func chooseClicked() { accept() }
    @objc private func useShellCompletion() { onShellCompletion?() }
    func numberOfRows(in tableView: NSTableView) -> Int { choices.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = choices[row]
        let title = NSTextField(labelWithString: choice.value)
        title.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: choice.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let cell = NSStackView(views: [title, detail])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 2
        title.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        return cell
    }
}
