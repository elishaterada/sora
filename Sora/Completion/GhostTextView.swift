import AppKit

/// Non-interactive overlay drawn above the terminal surface.
/// Hits pass through so Ghostty keeps mouse and focus.
final class GhostTextView: NSView {
    var text = "" {
        didSet {
            needsDisplay = true
            isHidden = text.isEmpty
        }
    }

    var font = SoraTheme.terminalFont {
        didSet { needsDisplay = true }
    }
    private var predicted = false
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let color = predicted
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let baseline = GhosttyInput.ghostTextBaseline(cellHeight: cellHeight, font: font)
        for (index, character) in text.enumerated() {
            let point = NSPoint(x: CGFloat(index) * cellWidth, y: baseline)
            String(character).draw(at: point, withAttributes: attributes)
        }
    }

    func show(
        text: String,
        origin: NSPoint,
        cellSize: NSSize,
        font: NSFont,
        predicted: Bool = false
    ) {
        self.font = font
        self.predicted = predicted
        self.cellWidth = cellSize.width > 0 ? cellSize.width : 8
        self.cellHeight = cellSize.height > 0 ? cellSize.height : 16
        self.text = text
        let columns = CGFloat(max(text.count, 1))
        frame = NSRect(
            x: origin.x,
            y: origin.y,
            width: ceil(self.cellWidth * columns) + 1,
            height: self.cellHeight
        )
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        text = ""
        predicted = false
        isHidden = true
    }
}
