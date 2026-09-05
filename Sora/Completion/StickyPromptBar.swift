import AppKit

/// Sticky footer under the Ghostty grid (Warp-style). Terminal scrollback never
/// draws through this strip — it is a sibling view, not an overlay on Metal.
final class StickyPromptBar: NSView {
    static let height: CGFloat = 52

    var onFocusTerminal: (() -> Void)?
    var onAcceptPrediction: (() -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let routeLabel = NSTextField(labelWithString: "")
    private let effectView: NSView
    private let hairline = NSView()
    private var showingPrediction = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = SoraTheme.nsGlassTint
            effectView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .withinWindow
            effect.state = .active
            effectView = effect
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        addSubview(effectView)
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        addSubview(hairline)

        configureLabel(pathLabel, size: 11, color: .secondaryLabelColor)
        configureLabel(lineLabel, size: 13, color: .labelColor)
        configureLabel(hintLabel, size: 11, color: .tertiaryLabelColor)
        configureLabel(routeLabel, size: 11, color: .controlAccentColor)
        lineLabel.font = SoraTheme.terminalFont.withSize(13)
        addSubview(pathLabel)
        addSubview(lineLabel)
        addSubview(hintLabel)
        addSubview(routeLabel)

        let click = NSClickGestureRecognizer(target: self, action: #selector(focusTerminal))
        addGestureRecognizer(click)
        let double = NSClickGestureRecognizer(target: self, action: #selector(acceptIfPossible))
        double.numberOfClicksRequired = 2
        addGestureRecognizer(double)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        hairline.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let inset: CGFloat = 14
        let top = bounds.height - 18
        pathLabel.frame = NSRect(
            x: inset,
            y: top - 12,
            width: max(0, bounds.width - inset * 2),
            height: 14
        )
        lineLabel.frame = NSRect(
            x: inset,
            y: 10,
            width: max(0, bounds.width - inset * 2 - 230),
            height: 18
        )
        hintLabel.frame = NSRect(
            x: bounds.width - inset - 118,
            y: 10,
            width: 118,
            height: 18
        )
        hintLabel.alignment = .right
        routeLabel.frame = NSRect(
            x: bounds.width - inset - 224,
            y: 10,
            width: 104,
            height: 18
        )
        routeLabel.alignment = .right
    }

    func update(
        path: String,
        branch: String?,
        line: String?,
        predicted: Bool
    ) {
        showingPrediction = predicted
        if let branch, !branch.isEmpty {
            pathLabel.stringValue = "\(path)  \(branch)"
        } else {
            pathLabel.stringValue = path
        }

        if let line, !line.isEmpty {
            lineLabel.stringValue = line
            lineLabel.textColor = predicted
                ? NSColor.controlAccentColor.withAlphaComponent(0.90)
                : NSColor.labelColor
            hintLabel.stringValue = predicted ? "→ accept" : ""
            hintLabel.isHidden = !predicted
        } else {
            lineLabel.stringValue = ""
            hintLabel.stringValue = ""
            hintLabel.isHidden = true
        }
        needsLayout = true
    }

    func updateRoute(_ intent: PromptIntent?) {
        if intent == .agent {
            // Warp-style continuation hint: Return opens Ask in this tab.
            routeLabel.stringValue = "↵ agent"
            hintLabel.stringValue = "⌘↩ shell"
            hintLabel.isHidden = false
        } else {
            routeLabel.stringValue = ""
            // Keep prediction's accept hint intact.
            if !showingPrediction {
                hintLabel.stringValue = ""
                hintLabel.isHidden = true
            }
        }
        routeLabel.isHidden = intent != .agent
        needsLayout = true
    }

    @objc private func focusTerminal() {
        onFocusTerminal?()
    }

    @objc private func acceptIfPossible() {
        onAcceptPrediction?()
        onFocusTerminal?()
    }

    private func configureLabel(_ label: NSTextField, size: CGFloat, color: NSColor) {
        label.font = .systemFont(ofSize: size, weight: .medium)
        label.textColor = color
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingMiddle
        label.drawsBackground = false
    }
}
