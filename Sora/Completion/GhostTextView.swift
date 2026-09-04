import AppKit
import CoreText

/// Non-interactive overlay drawn above the terminal surface.
/// Hits pass through so Ghostty keeps mouse and focus.
final class GhostTextView: NSView {
    var text = "" {
        didSet {
            needsDisplay = true
            isHidden = text.isEmpty
        }
    }

    private var predicted = false
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var baseline: CGFloat = 0
    private var ctFont: CTFont = SoraTheme.terminalCTFont

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let color = predicted
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.55)

        for (index, character) in text.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: ctFont as Any,
                .foregroundColor: color,
            ]
            let run = NSAttributedString(string: String(character), attributes: attrs)
            let line = CTLineCreateWithAttributedString(run)
            let x = CGFloat(index) * cellWidth
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
            let glyphX = x + max((cellWidth - CGFloat(advance)) / 2, 0)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: glyphX, y: baseline)
            CTLineDraw(line, context)
        }
    }

    func show(
        text: String,
        origin: NSPoint,
        cellSize: NSSize,
        font: CTFont,
        predicted: Bool = false
    ) {
        self.ctFont = font
        self.predicted = predicted
        self.cellWidth = cellSize.width > 0 ? cellSize.width : 8
        self.cellHeight = cellSize.height > 0 ? cellSize.height : 16
        self.baseline = GhosttyInput.ghostTextBaseline(cellHeight: self.cellHeight, font: font)
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
