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
    private var cellHeight: CGFloat = 16
    private var baseline: CGFloat = 0
    private var ctFont: CTFont = SoraTheme.terminalCTFont

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let color = predicted
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        // NSString drawing follows AppKit's view coordinates; CTLineDraw can
        // disagree with the NSView CTM and shift the baseline.
        let font = ctFont as NSFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        (text as NSString).draw(at: NSPoint(x: 0, y: baseline), withAttributes: attrs)
    }

    func show(
        text: String,
        origin: NSPoint,
        cellHeight: CGFloat,
        font: CTFont,
        predicted: Bool = false
    ) {
        self.ctFont = font
        self.predicted = predicted
        self.cellHeight = cellHeight > 0 ? cellHeight : 16
        self.baseline = GhosttyInput.ghostTextBaseline(cellHeight: self.cellHeight, font: font)
        self.text = text
        let attrs: [NSAttributedString.Key: Any] = [.font: font as Any]
        let width = (text as NSString).size(withAttributes: attrs).width
        frame = NSRect(
            x: origin.x,
            y: origin.y,
            width: ceil(width) + 2,
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
