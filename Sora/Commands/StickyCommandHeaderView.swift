import AppKit

/// Overlays the existing terminal viewport, so appearing never resizes the PTY.
final class StickyCommandHeaderView: NSView {
    private let content = NSView()
    private let commandLabel = NSTextField(labelWithString: "")
    private let divider = NSView()
    private var fullHeight: CGFloat = 48

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 20.0 / 255, green: 22.0 / 255,
                                        blue: 26.0 / 255, alpha: 1).cgColor
        commandLabel.textColor = .labelColor
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.maximumNumberOfLines = 1
        addSubview(content)
        content.addSubview(commandLabel)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(divider)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command for visible output")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(command: String, remainingHeight: CGFloat, sourceY: CGFloat, viewport: NSRect, cellHeight: CGFloat) {
        fullHeight = max(44, cellHeight + 24)
        // Equivalent to position: sticky: follow the command, clamp at the top,
        // then let the next command push the whole header out. Use scroll
        // coordinates directly, never a time-based animation that lags gestures.
        let naturalTop = max(0, sourceY - 6)
        let top = min(naturalTop, remainingHeight - 6 - fullHeight)

        commandLabel.stringValue = command.replacingOccurrences(of: "\n", with: " ↵ ")
        commandLabel.font = SoraTheme.terminalFont
        commandLabel.toolTip = command
        setAccessibilityValue(command)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Include the complete incoming header below the pinned band so its
        // text cannot be clipped halfway over the original terminal command.
        frame = NSRect(x: 0, y: viewport.height - fullHeight * 2, width: viewport.width, height: fullHeight * 2)
        content.frame = NSRect(x: 0, y: fullHeight - top, width: viewport.width, height: fullHeight)
        isHidden = top >= fullHeight || top + fullHeight <= 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let labelHeight = ceil(commandLabel.font?.boundingRectForFont.height ?? 20)
        // Keep the label anchored to the bottom while the next boundary pushes
        // the header upward. The layer clips the departing command at the top.
        commandLabel.frame = NSRect(x: 24, y: (fullHeight - labelHeight) / 2,
                                   width: max(0, bounds.width - 48), height: labelHeight)
        divider.frame = NSRect(x: 0, y: 0, width: bounds.width,
                               height: 1 / (window?.backingScaleFactor ?? 1))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local), content.frame.contains(local) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // Preserve the terminal's click-to-select-block behavior under the header.
        superview?.mouseDown(with: event)
    }
}
