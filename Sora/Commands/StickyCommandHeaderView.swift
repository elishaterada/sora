import AppKit

/// Overlays the existing terminal viewport, so appearing never resizes the PTY.
final class StickyCommandHeaderView: NSView {
    private let content = NSVisualEffectView()
    private let tint = NSView()
    private let commandLabel = TerminalCommandLabel(labelWithString: "")
    private let divider = NSView()
    private var fullHeight: CGFloat = 48

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        // Sample behind the window, not the scrolling glyphs beneath the header.
        // This keeps the desktop frost without letting two commands overlap.
        content.material = .underWindowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        tint.wantsLayer = true
        tint.layer?.backgroundColor = CommandHeaderStyle.background.cgColor
        content.addSubview(tint)
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

    func update(command: NSAttributedString, font: NSFont, failed: Bool, remainingHeight: CGFloat, sourceY: CGFloat, viewport: NSRect, cellHeight: CGFloat) {
        fullHeight = max(44, cellHeight + 24)
        // Equivalent to position: sticky: follow the command, clamp at the top,
        // then let the next command push the whole header out. Use scroll
        // coordinates directly, never a time-based animation that lags gestures.
        let naturalTop = max(0, sourceY - 6)
        let top = min(naturalTop, remainingHeight - 6 - fullHeight)

        commandLabel.font = font
        commandLabel.attributedStringValue = CommandHeaderStyle.singleLine(command)
        commandLabel.toolTip = command.string
        setAccessibilityValue(command.string)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.layer?.backgroundColor = (failed ? CommandHeaderStyle.errorBackground : CommandHeaderStyle.background).cgColor
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
        tint.frame = content.bounds
        let labelHeight = ceil(commandLabel.font?.boundingRectForFont.height ?? 20)
        // Keep the label anchored to the bottom while the next boundary pushes
        // the header upward. The layer clips the departing command at the top.
        // NSTextField adds a 2pt text inset; align glyphs with the 24pt grid.
        commandLabel.frame = NSRect(x: SoraTheme.gridPaddingX - 2, y: (fullHeight - labelHeight) / 2,
                                   width: max(0, bounds.width - SoraTheme.gridPaddingX * 2), height: labelHeight)
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

/// Ghostty rasterizes without AppKit's optical font thickening.
private final class TerminalCommandLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
        context.restoreGState()
    }
}
