import AppKit

/// Pairs the Ghostty grid with a sticky prompt footer so scrollback never
/// paints through the input strip.
final class TerminalPaneView: NSView {
    let surface: GhosttySurfaceView
    let stickyBar = StickyPromptBar()

    override var isOpaque: Bool { false }

    init(surface: GhosttySurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = SoraTheme.nsClear.cgColor
        addSubview(surface)
        addSubview(stickyBar)
        surface.autoresizingMask = []
        stickyBar.autoresizingMask = []
        surface.attachStickyPromptBar(stickyBar)
        stickyBar.onFocusTerminal = { [weak surface] in
            guard let surface else { return }
            surface.window?.makeFirstResponder(surface)
        }
        stickyBar.onAcceptPrediction = { [weak surface] in
            surface?.acceptStickyPrediction()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setActive(_ active: Bool) {
        isHidden = !active
        surface.setActive(active)
    }

    override func layout() {
        super.layout()
        let barH = StickyPromptBar.height
        stickyBar.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: barH
        )
        surface.frame = NSRect(
            x: 0,
            y: barH,
            width: bounds.width,
            height: max(0, bounds.height - barH)
        )
    }
}
