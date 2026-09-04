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

    private var positionTimer: Timer?
    private var cursorOrigin: (() -> NSPoint?)?

    deinit { positionTimer?.invalidate() }

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

        // One glyph per terminal cell, left-aligned like Ghostty — do not
        // center in the cell or advances drift from the rendered grid.
        for (index, character) in text.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: ctFont as Any,
                .foregroundColor: color,
            ]
            let run = NSAttributedString(string: String(character), attributes: attrs)
            let line = CTLineCreateWithAttributedString(run)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: CGFloat(index) * cellWidth, y: baseline)
            CTLineDraw(line, context)
        }
    }

    func show(
        text: String,
        origin: NSPoint,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        font: CTFont,
        predicted: Bool = false,
        cursorOrigin: (() -> NSPoint?)? = nil
    ) {
        self.cursorOrigin = cursorOrigin
        self.ctFont = font
        self.predicted = predicted
        self.cellWidth = cellWidth > 0 ? cellWidth : 8
        self.cellHeight = cellHeight > 0 ? cellHeight : 16
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
        // PTY echo updates Ghostty on its own renderer thread; app wakeups
        // are not cursor-change notifications. Follow it while text is visible.
        if cursorOrigin != nil, positionTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.updateCursorOrigin()
            }
            positionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func updateCursorOrigin() {
        guard let cursorOrigin else { return }
        guard let origin = cursorOrigin() else {
            hide()
            return
        }
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    func hide() {
        positionTimer?.invalidate()
        positionTimer = nil
        cursorOrigin = nil
        text = ""
        predicted = false
        isHidden = true
    }
}
