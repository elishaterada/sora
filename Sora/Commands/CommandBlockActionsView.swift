import AppKit

/// A real responder for selected output, independent of the shell input. Its
/// reserved slot keeps the terminal grid stable as keyboard focus moves.
final class CommandBlockActionsView: NSView, NSMenuItemValidation {
    weak var terminal: GhosttySurfaceView?
    var onKey: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?
    var onCopyOutput: (() -> Void)?
    var onReuse: (() -> Void)?
    var onReturnToInput: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "↑ ↓ Blocks   esc Input")
    private var buttons: [NSButton] = []

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.18, green: 0.16, blue: 0.13, alpha: 1).cgColor
        label.font = SoraTheme.terminalFont.withSize(12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        addSubview(label)
        addSubview(hint)
        addButton("doc.on.doc", "Copy Output", #selector(copyOutput))
        addButton("arrow.turn.down.left", "Use Command in Input (Return)", #selector(reuse))
        addButton("ellipsis", "Block Actions (Tab)", #selector(showActions))
        addButton("xmark", "Return to Input (Escape)", #selector(returnToInput))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Selected command block")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func addButton(_ symbol: String, _ title: String, _ action: Selector) {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                              target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        addSubview(button)
        buttons.append(button)
    }

    func update(command: String) {
        label.stringValue = command.replacingOccurrences(of: "\n", with: " ↵ ")
        label.toolTip = command
        setAccessibilityValue(command)
    }

    override func layout() {
        super.layout()
        let actionWidth = CGFloat(buttons.count) * 30
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: bounds.width - 16 - actionWidth + CGFloat(index) * 30,
                                  y: 4, width: 28, height: 28)
        }
        hint.isHidden = bounds.width < 560
        let hintWidth: CGFloat = hint.isHidden ? 0 : 148
        hint.frame = NSRect(x: bounds.width - 24 - actionWidth - hintWidth,
                            y: 11, width: hintWidth, height: 15)
        label.frame = NSRect(x: 24, y: 10,
                             width: max(0, bounds.width - 56 - actionWidth - hintWidth), height: 17)
    }

    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func keyUp(with event: NSEvent) { onKeyUp?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        terminal?.performKeyEquivalent(with: event) ?? false
    }
    @objc func copy(_ sender: Any?) { terminal?.copy(sender) }
    @objc func paste(_ sender: Any?) { terminal?.paste(sender) }
    override func selectAll(_ sender: Any?) { terminal?.selectAll(sender) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        terminal?.validateMenuItem(menuItem) ?? false
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    @objc private func copyOutput() { onCopyOutput?() }
    @objc private func reuse() { onReuse?() }
    @objc private func returnToInput() { onReturnToInput?() }
    @objc func showActions() {
        guard let menu = makeMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: max(16, bounds.width - 240), y: bounds.height), in: self)
    }
}
