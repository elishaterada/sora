import AppKit

/// Sticky footer under the Ghostty grid (Warp-style). Terminal scrollback never
/// draws through this strip — it is a sibling view, not an overlay on Metal.
final class StickyPromptBar: NSView {
    static let height: CGFloat = 52

    var onFocusTerminal: (() -> Void)?
    var onAcceptPrediction: (() -> Void)?

    private let pathButton = NSButton(title: "", target: nil, action: nil)
    private let branchButton = NSButton(title: "", target: nil, action: nil)
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

        configureChipButton(pathButton, action: #selector(showPathMenu(_:)))
        configureChipButton(branchButton, action: #selector(showBranchMenu(_:)))
        configureLabel(lineLabel, size: 13, color: .labelColor)
        configureLabel(hintLabel, size: 11, color: .tertiaryLabelColor)
        configureLabel(routeLabel, size: 11, color: .controlAccentColor)
        lineLabel.font = SoraTheme.terminalFont.withSize(13)
        addSubview(pathButton)
        addSubview(branchButton)
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
        pathButton.sizeToFit()
        branchButton.sizeToFit()
        let pathWidth = min(pathButton.fittingSize.width + 8, bounds.width * 0.45)
        pathButton.frame = NSRect(x: inset, y: top - 14, width: pathWidth, height: 18)
        let branchX = pathButton.frame.maxX + 6
        let branchWidth = branchButton.isHidden ? 0 : min(branchButton.fittingSize.width + 8, 160)
        branchButton.frame = NSRect(x: branchX, y: top - 14, width: branchWidth, height: 18)
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
        directory: URL?,
        branch: String?,
        line: String?,
        predicted: Bool
    ) {
        showingPrediction = predicted
        currentDirectory = directory
        currentBranch = branch
        pathButton.title = path
        pathButton.toolTip = directory?.path ?? path
        if let branch, !branch.isEmpty {
            branchButton.title = branch
            branchButton.isHidden = false
            branchButton.toolTip = "Branch \(branch)"
        } else {
            branchButton.title = ""
            branchButton.isHidden = true
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
            applyFallbackHint()
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
        } else if agentResumeAvailable {
            hintLabel.stringValue = "⌘Y continue"
            hintLabel.isHidden = false
        } else {
            hintLabel.stringValue = ""
            hintLabel.isHidden = true
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
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealDirectory), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyDirectoryPath), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Display Path", action: #selector(copyDirectoryDisplayPath), keyEquivalent: "")
        for item in menu.items { item.target = self }
        let location = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func showBranchMenu(_ sender: NSButton) {
        guard let branch = currentBranch else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Branch Name", action: #selector(copyBranchName), keyEquivalent: "")
        if currentDirectory.flatMap({ GitRepository.root(containing: $0) }) != nil {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Reveal Repository", action: #selector(revealRepository), keyEquivalent: "")
        }
        for item in menu.items where item.action != nil { item.target = self }
        _ = branch
        let location = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func revealDirectory() {
        guard let directory = currentDirectory else { return }
        PathActions.reveal(directory)
    }

    @objc private func copyDirectoryPath() {
        guard let directory = currentDirectory else { return }
        PathActions.copyPath(directory)
    }

    @objc private func copyDirectoryDisplayPath() {
        guard let directory = currentDirectory else { return }
        PathActions.copyDisplayPath(directory)
    }

    @objc private func copyBranchName() {
        guard let branch = currentBranch else { return }
        PathActions.copy(branch)
    }

    @objc private func revealRepository() {
        guard let directory = currentDirectory,
              let root = GitRepository.root(containing: directory) else { return }
        PathActions.reveal(root)
    }

    private func configureChipButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.alignment = .left
        button.setButtonType(.momentaryChange)
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
