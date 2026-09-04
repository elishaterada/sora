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

    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { needsDisplay = true }
    }
    private var predicted = false

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
        (text as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attributes)
    }

    func show(
        text: String,
        origin: NSPoint,
        height: CGFloat,
        font: NSFont,
        predicted: Bool = false
    ) {
        self.font = font
        self.predicted = predicted
        self.text = text
        let size = (text as NSString).size(withAttributes: [.font: font])
        frame = NSRect(
            x: origin.x,
            y: origin.y,
            width: ceil(size.width) + 1,
            height: max(height, ceil(size.height))
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
