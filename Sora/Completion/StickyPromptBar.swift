import AppKit

/// Sticky footer under the Ghostty grid. Terminal scrollback never draws
/// through this strip — it is a sibling view, not an overlay on Metal.
final class StickyPromptBar: NSView, NSGestureRecognizerDelegate {
    /// Single-row chrome: chip height + tight vertical inset.
    static let height: CGFloat = 34

    var onFocusTerminal: (() -> Void)?
    var onAcceptPrediction: (() -> Void)?

    private let pathButton = StickyContextChipButton()
    private let branchButton = StickyContextChipButton()
    private let lineLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let routeLabel = NSTextField(labelWithString: "")
    private let effectView: NSView
    private let hairline = NSView()
    private var showingPrediction = false
    private var agentResumeAvailable = false
    private var currentDirectory: URL?
    private var currentBranch: String?

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

        pathButton.symbolName = "folder"
        pathButton.target = self
        pathButton.action = #selector(showPathMenu(_:))
        branchButton.symbolName = "arrow.triangle.branch"
        branchButton.target = self
        branchButton.action = #selector(showBranchMenu(_:))
        addSubview(pathButton)
        addSubview(branchButton)

        configureLabel(lineLabel, size: SoraTheme.chromeSize, color: .labelColor)
        configureLabel(hintLabel, size: SoraTheme.chromeCaptionSize, color: .tertiaryLabelColor)
        configureLabel(routeLabel, size: SoraTheme.chromeCaptionSize, color: SoraTheme.nsAccent)
        lineLabel.font = SoraTheme.terminalFont.withSize(SoraTheme.chromeSize)
        addSubview(lineLabel)
        addSubview(hintLabel)
        addSubview(routeLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Prompt bar")

        let click = NSClickGestureRecognizer(target: self, action: #selector(focusTerminal))
        click.delegate = self
        addGestureRecognizer(click)
        let double = NSClickGestureRecognizer(target: self, action: #selector(acceptIfPossible))
        double.numberOfClicksRequired = 2
        double.delegate = self
        addGestureRecognizer(double)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        // Let path/branch chips receive clicks instead of focus-terminal.
        if pathButton.frame.contains(point) || (!branchButton.isHidden && branchButton.frame.contains(point)) {
            return false
        }
        return true
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        hairline.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let inset = SoraTheme.chromeInset
        let chipHeight = min(SoraTheme.hitCompact, bounds.height - 4)
        let rowY = (bounds.height - chipHeight) / 2
        let labelHeight: CGFloat = 16
        let labelY = (bounds.height - labelHeight) / 2

        pathButton.sizeToFit()
        branchButton.sizeToFit()
        let pathWidth = min(
            max(pathButton.fittingSize.width, pathButton.intrinsicContentSize.width),
            bounds.width * 0.40
        )
        pathButton.frame = NSRect(x: inset, y: rowY, width: pathWidth, height: chipHeight)
        let branchX = pathButton.frame.maxX + 4
        let branchWidth = branchButton.isHidden
            ? 0
            : min(max(branchButton.fittingSize.width, branchButton.intrinsicContentSize.width), 160)
        branchButton.frame = NSRect(x: branchX, y: rowY, width: branchWidth, height: chipHeight)

        let trailingReserve: CGFloat = {
            var width: CGFloat = 0
            if !hintLabel.isHidden, !hintLabel.stringValue.isEmpty { width += 96 }
            if !routeLabel.isHidden, !routeLabel.stringValue.isEmpty { width += 72 }
            return width
        }()
        let chipsEnd = branchButton.isHidden ? pathButton.frame.maxX : branchButton.frame.maxX
        let lineX = chipsEnd + 8
        let lineMaxX = bounds.width - inset - trailingReserve
        lineLabel.frame = NSRect(
            x: lineX,
            y: labelY,
            width: max(0, lineMaxX - lineX),
            height: labelHeight
        )

        var trailingX = bounds.width - inset
        if !hintLabel.isHidden, !hintLabel.stringValue.isEmpty {
            let w: CGFloat = 92
            trailingX -= w
            hintLabel.frame = NSRect(x: trailingX, y: labelY, width: w, height: labelHeight)
            hintLabel.alignment = .right
            trailingX -= 4
        } else {
            hintLabel.frame = .zero
        }
        if !routeLabel.isHidden, !routeLabel.stringValue.isEmpty {
            let w: CGFloat = 68
            trailingX -= w
            routeLabel.frame = NSRect(x: trailingX, y: labelY, width: w, height: labelHeight)
            routeLabel.alignment = .right
        } else {
            routeLabel.frame = .zero
        }
    }

    func update(
        path: String,
        directory: URL?,
        branch: String?,
        line: String?,
        predicted: Bool
    ) {
        showingPrediction = predicted
        currentDirectory = directory
        currentBranch = branch
        pathButton.chipTitle = path
        pathButton.toolTip = directory.map { "\($0.path)\nClick for path actions" } ?? "\(path)\nClick for path actions"
        pathButton.setAccessibilityLabel("Working directory \(path)")
        pathButton.isEnabled = directory != nil
        if let branch, !branch.isEmpty {
            branchButton.chipTitle = branch
            branchButton.isHidden = false
            branchButton.toolTip = "Branch \(branch)\nClick for branch actions"
            branchButton.setAccessibilityLabel("Git branch \(branch)")
        } else {
            branchButton.chipTitle = ""
            branchButton.isHidden = true
            branchButton.setAccessibilityLabel(nil)
        }

        if let line, !line.isEmpty {
            lineLabel.stringValue = line
            lineLabel.textColor = predicted
                ? SoraTheme.nsAccent.withAlphaComponent(0.90)
                : NSColor.labelColor
            lineLabel.setAccessibilityLabel(predicted ? "Prediction: \(line)" : "Prompt line: \(line)")
            hintLabel.stringValue = predicted ? "→ accept" : ""
            hintLabel.isHidden = !predicted
            hintLabel.setAccessibilityLabel(predicted ? "Press Tab or Right Arrow to accept prediction" : nil)
        } else {
            lineLabel.stringValue = ""
            lineLabel.setAccessibilityLabel(nil)
            applyFallbackHint()
        }
        needsLayout = true
    }

    func updateRoute(_ intent: PromptIntent?) {
        if intent == .agent {
            routeLabel.stringValue = "↵ agent"
            hintLabel.stringValue = "⌘↵ shell"
            hintLabel.isHidden = false
            routeLabel.setAccessibilityLabel("Return sends to Agent")
            hintLabel.setAccessibilityLabel("Command-Return runs as shell")
            setAccessibilityValue("Agent routing armed")
        } else {
            routeLabel.stringValue = ""
            routeLabel.setAccessibilityLabel(nil)
            setAccessibilityValue(nil)
            applyFallbackHint()
        }
        routeLabel.isHidden = intent != .agent
        needsLayout = true
    }

    func updateAgentResumeHint(_ available: Bool) {
        agentResumeAvailable = available
        if routeLabel.stringValue.isEmpty {
            applyFallbackHint()
        }
        needsLayout = true
    }

    private func applyFallbackHint() {
        if showingPrediction {
            hintLabel.stringValue = "→ accept"
            hintLabel.isHidden = false
            hintLabel.setAccessibilityLabel("Press Tab or Right Arrow to accept prediction")
        } else if agentResumeAvailable {
            hintLabel.stringValue = "⌘Y continue"
            hintLabel.isHidden = false
            hintLabel.setAccessibilityLabel("Command-Y reopens the agent conversation")
        } else {
            hintLabel.stringValue = ""
            hintLabel.isHidden = true
            hintLabel.setAccessibilityLabel(nil)
        }
    }

    @objc private func focusTerminal() {
        onFocusTerminal?()
    }

    @objc private func acceptIfPossible() {
        onAcceptPrediction?()
        onFocusTerminal?()
    }

    @objc private func showPathMenu(_ sender: NSButton) {
        guard let directory = currentDirectory else {
            onFocusTerminal?()
            return
        }
        let menu = NSMenu()
        for action in ContextChipActions.path(directory) where !action.isDivider {
            let item = NSMenuItem(title: action.title, action: #selector(runPathAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.handler
            menu.addItem(item)
        }
        let location = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func showBranchMenu(_ sender: NSButton) {
        guard let branch = currentBranch else { return }
        let menu = NSMenu()
        let root = currentDirectory.flatMap { GitRepository.root(containing: $0) }
        for action in ContextChipActions.branch(branch, repositoryRoot: root) {
            if action.isDivider {
                menu.addItem(.separator())
            } else {
                let item = NSMenuItem(title: action.title, action: #selector(runPathAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.handler
                menu.addItem(item)
            }
        }
        let location = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func runPathAction(_ sender: NSMenuItem) {
        (sender.representedObject as? (() -> Void))?()
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
        label.setAccessibilityElement(true)
    }
}

/// Path/branch chip matching chrome `ContextChip`: icon + label, hover wash, menu.
private final class StickyContextChipButton: NSButton {
    var symbolName = "folder" {
        didSet { rebuildTitle() }
    }

    var chipTitle = "" {
        didSet { rebuildTitle() }
    }

    private var hovering = false
    private var tracking: NSTrackingArea?

    override class var cellClass: AnyClass? {
        get { StickyContextChipCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        font = .systemFont(ofSize: SoraTheme.chromeCaptionSize, weight: .medium)
        contentTintColor = SoraTheme.nsAccent
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityRole(.button)
        rebuildTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += StickyContextChipCell.padX * 2
        size.height = max(size.height, SoraTheme.hitCompact)
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = hovering
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }

    private func rebuildTitle() {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        title = chipTitle
        imagePosition = chipTitle.isEmpty ? .imageOnly : .imageLeading
        invalidateIntrinsicContentSize()
    }
}

private final class StickyContextChipCell: NSButtonCell {
    static let padX: CGFloat = 6
    static let padY: CGFloat = 2

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let inset = cellFrame.insetBy(dx: Self.padX, dy: Self.padY)
        super.drawInterior(withFrame: inset, in: controlView)
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        var size = super.cellSize(forBounds: rect)
        size.width += Self.padX * 2
        size.height = max(size.height + Self.padY * 2, SoraTheme.hitCompact)
        return size
    }
}
