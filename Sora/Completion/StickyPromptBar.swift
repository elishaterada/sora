import AppKit

/// Sticky footer under the Ghostty grid. Terminal scrollback never draws
/// through this strip — it is a sibling view, not an overlay on Metal.
final class StickyPromptBar: NSView, NSGestureRecognizerDelegate {
    /// Context, live shell input preview, and keyboard hints.
    static let height: CGFloat = 112

    var maximumHeight: CGFloat = height {
        didSet { if maximumHeight != oldValue { needsLayout = true } }
    }
    private var firstVisibleLine = 0
    private var scrollRemainder: CGFloat = 0
    private var followCaret = true
    var onHeightChange: (() -> Void)?
    private(set) var preferredHeight: CGFloat = height
    private var historyPreviewHeight: CGFloat?
    var onMoveCursor: ((Int) -> Void)?
    private var selectionAnchor: Int?
    private var selectionRange: Range<Int>?
    private var hitRows: [(text: String, start: Int)] = []
    var onFocusTerminal: (() -> Void)?
    var onAcceptPrediction: (() -> Void)?
    var onToggleDictation: (() -> Void)?

    private struct WrapKey: Equatable {
        let text: String
        let cursor: Int
        let width: CGFloat
        let font: NSFont
    }
    private var wrappedKey: WrapKey?
    private var wrappedInput: StickyPromptBarModel.WrappedInput?
    private var promptReady = false
    private var hasInput = false
    private var focusObservers: [NSObjectProtocol] = []
    private let inputClip = NSView()
    private let caret = NSView()
    private var displayText = ""
    private var caretText = ""
    private var caretScalarOffset = 0
    private var caretVisible = false
    private let inputSymbol = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Running")
    private let pathButton = StickyContextChipButton()
    private let branchButton = StickyContextChipButton()
    private let lineLabel = NSTextField(labelWithString: "")
    private var hintUpdate: DispatchWorkItem?
    private var desiredHint = "" {
        didSet {
            guard desiredHint != oldValue else { return }
            hintUpdate?.cancel()
            let text = desiredHint
            let update = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hintLabel.stringValue = text
                self.hintLabel.setAccessibilityLabel(text)
                self.hintLabel.isHidden = false
            }
            hintUpdate = update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: update)
        }
    }
    private let hintLabel = NSTextField(labelWithString: "")
    private let routeLabel = NSTextField(labelWithString: "")
    private let effectView: NSView
    private let microphoneButton = NSButton()
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
        configureLabel(statusLabel, size: SoraTheme.chromeCaptionSize, color: .secondaryLabelColor)
        statusLabel.font = .systemFont(ofSize: SoraTheme.chromeCaptionSize, weight: .semibold)
        addSubview(statusLabel)
        inputSymbol.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        inputSymbol.contentTintColor = SoraTheme.nsAccent
        addSubview(inputSymbol)

        configureLabel(lineLabel, size: SoraTheme.chromeSize, color: .labelColor)
        configureLabel(hintLabel, size: SoraTheme.chromeCaptionSize, color: NSColor.white.withAlphaComponent(0.65))
        configureLabel(routeLabel, size: SoraTheme.chromeCaptionSize, color: SoraTheme.nsAccent)
        lineLabel.font = SoraTheme.terminalFont.withSize(16)
        inputClip.wantsLayer = true
        inputClip.layer?.masksToBounds = true
        addSubview(inputClip)
        inputClip.addSubview(lineLabel)
        caret.wantsLayer = true
        caret.layer?.backgroundColor = SoraTheme.nsAccent.cgColor
        inputClip.addSubview(caret)
        resetCaretBlink()
        addSubview(hintLabel)
        addSubview(routeLabel)
        microphoneButton.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictate")
        microphoneButton.isBordered = false
        microphoneButton.target = self
        microphoneButton.action = #selector(toggleDictation)
        microphoneButton.toolTip = "Dictate into the terminal"
        microphoneButton.setAccessibilityElement(true)
        microphoneButton.setAccessibilityLabel("Dictate into the terminal")
        addSubview(microphoneButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Prompt bar")

        let click = NSClickGestureRecognizer(target: self, action: #selector(clickInput(_:)))
        click.delegate = self
        addGestureRecognizer(click)
        let drag = NSPanGestureRecognizer(target: self, action: #selector(selectInput(_:)))
        drag.delegate = self
        addGestureRecognizer(drag)
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
        if pathButton.frame.contains(point) || microphoneButton.frame.contains(point)
            || (!branchButton.isHidden && branchButton.frame.contains(point)) {
            return false
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.needsLayout = true
            })
        }
    }

    deinit {
        hintUpdate?.cancel()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        hairline.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
        let inset: CGFloat = 24
        let chipHeight: CGFloat = 26
        let contextY = bounds.height - 38
        statusLabel.frame = NSRect(x: max(inset, bounds.width - 88), y: contextY + 5, width: 72, height: 16)
        statusLabel.alignment = .right
        pathButton.sizeToFit()
        branchButton.sizeToFit()
        let pathWidth = min(max(pathButton.intrinsicContentSize.width, 40), max(40, bounds.width * 0.4))
        pathButton.frame = NSRect(x: inset, y: contextY, width: pathWidth, height: chipHeight)
        let branchWidth = branchButton.isHidden ? 0 : min(max(branchButton.intrinsicContentSize.width, 40), max(40, bounds.width - pathWidth - 128))
        branchButton.frame = NSRect(x: pathButton.frame.maxX + 8, y: contextY, width: branchWidth, height: chipHeight)
        let font = lineLabel.font ?? SoraTheme.terminalFont
        let width = max(1, bounds.width - inset * 2 - 24 - 8)
        let key = WrapKey(text: displayText, cursor: caretScalarOffset, width: width, font: font)
        let wrapped: StickyPromptBarModel.WrappedInput
        if wrappedKey == key, let cached = wrappedInput {
            wrapped = cached
        } else {
            wrapped = StickyPromptBarModel.wrap(displayText, cursorOffset: caretScalarOffset, width: width) {
                ($0 as NSString).size(withAttributes: [.font: font]).width
            }
            wrappedKey = key
            wrappedInput = wrapped
        }
        let lines = wrapped.lines
        let visibleLines = StickyPromptBarModel.visibleLineCount(
            total: lines.count, maximumHeight: historyPreviewHeight ?? maximumHeight)
        let height = historyPreviewHeight ?? (Self.height + CGFloat(visibleLines - 1) * 24)
        if preferredHeight != height {
            preferredHeight = height
            onHeightChange?()
        }
        if followCaret {
            firstVisibleLine = max(0, wrapped.cursorRow + 1 - visibleLines)
            followCaret = false
        }
        firstVisibleLine = min(max(0, firstVisibleLine), max(0, lines.count - visibleLines))
        let firstLine = firstVisibleLine
        hitRows = Array(zip(lines, wrapped.starts).dropFirst(firstLine).prefix(visibleLines)).map { (text: $0.0, start: $0.1) }
        let visibleText = lines.dropFirst(firstLine).prefix(visibleLines).joined(separator: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 24
        paragraph.maximumLineHeight = 24
        paragraph.lineBreakMode = .byClipping
        lineLabel.maximumNumberOfLines = 0
        lineLabel.cell?.usesSingleLineMode = false
        let styled = NSMutableAttributedString(string: visibleText, attributes: [
            .font: font, .foregroundColor: lineLabel.textColor ?? NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        if let selectionRange {
            var utf16Start = 0
            for row in hitRows {
                let count = row.text.unicodeScalars.count
                let lower = max(selectionRange.lowerBound, row.start)
                let upper = min(selectionRange.upperBound, row.start + count)
                if lower < upper {
                    let prefix = String(row.text.unicodeScalars.prefix(lower - row.start))
                    let selected = String(row.text.unicodeScalars.dropFirst(lower - row.start).prefix(upper - lower))
                    styled.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor,
                                        range: NSRange(location: utf16Start + prefix.utf16.count, length: selected.utf16.count))
                }
                utf16Start += row.text.utf16.count + 1
            }
        }
        lineLabel.attributedStringValue = styled
        inputClip.frame = NSRect(x: inset + 24, y: 42, width: max(0, bounds.width - inset * 2 - 24), height: CGFloat(visibleLines) * 24)
        let cursorX = (wrapped.cursorPrefix as NSString).size(withAttributes: [.font: font]).width
        let textWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let offset = max(0, cursorX - inputClip.bounds.width + 8)
        lineLabel.frame = NSRect(x: -offset, y: 0, width: max(inputClip.bounds.width, textWidth + 8), height: inputClip.bounds.height)
        // Anchor all cues to the text field's actual baseline, including its cell
        // inset. Fixed offsets drift from the placeholder and wrapped input.
        let firstBaseline = lineLabel.frame.maxY - lineLabel.firstBaselineOffsetFromTop
        let cursorBaseline = firstBaseline - CGFloat(wrapped.cursorRow - firstLine) * 24
        caret.frame = NSRect(x: cursorX - offset, y: cursorBaseline + font.descender,
                             width: 1.5, height: font.ascender - font.descender)
        let symbolHeight = font.capHeight
        inputSymbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium)
        inputSymbol.frame = NSRect(x: inset, y: inputClip.frame.minY + firstBaseline,
                                   width: 12, height: symbolHeight)
        caret.isHidden = !caretVisible || window?.isKeyWindow != true
            || wrapped.cursorRow < firstLine || wrapped.cursorRow >= firstLine + visibleLines
        hintLabel.frame = NSRect(x: inset, y: 12, width: max(0, bounds.width - 160), height: 16)
        hintLabel.alignment = .left
        routeLabel.frame = NSRect(x: max(inset, bounds.width - 130), y: 12, width: 76, height: 16)
        routeLabel.alignment = .right
        microphoneButton.frame = NSRect(x: bounds.width - inset - 24, y: 7, width: 24, height: 26)
    }

    override func scrollWheel(with event: NSEvent) {
        guard inputClip.frame.contains(convert(event.locationInWindow, from: nil)),
              let wrappedInput, wrappedInput.lines.count > hitRows.count else {
            super.scrollWheel(with: event)
            return
        }
        scrollRemainder -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 24)
        let rows = Int(scrollRemainder / 24)
        scrollRemainder -= CGFloat(rows) * 24
        firstVisibleLine = min(max(0, firstVisibleLine + rows), wrappedInput.lines.count - hitRows.count)
        followCaret = false
        needsLayout = true
    }

    func update(
        path: String,
        directory: URL?,
        branch: String?,
        line: String?,
        predicted: Bool
    ) {
        showingPrediction = predicted
        hasInput = !(line?.isEmpty ?? true)
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
            desiredHint = predicted ? "Tab  Accept suggestion" : "Return  Run command"
            hintLabel.isHidden = false
            hintLabel.setAccessibilityLabel(predicted ? "Press Tab or Right Arrow to accept prediction" : nil)
        } else {
            lineLabel.stringValue = promptReady ? "Type a command, or ask Agent…" : "Command running…"
            lineLabel.textColor = .secondaryLabelColor
            lineLabel.setAccessibilityLabel("Terminal input preview")
            applyFallbackHint()
        }
        displayText = lineLabel.stringValue
        needsLayout = true
    }

    func updateSuggestion(_ suffix: String?) {
        guard promptReady, let suffix, !suffix.isEmpty else {
            hintLabel.toolTip = nil
            return
        }
        desiredHint = "Tab  Complete: " + suffix.replacingOccurrences(of: "\n", with: " ↵ ")
        hintLabel.isHidden = false
        hintLabel.toolTip = suffix
        hintLabel.setAccessibilityLabel("Press Tab to complete with " + suffix)
    }

    /// Restart with a visible caret, including keys whose shell echo arrives later.
    func resetCaretBlink() {
        guard let layer = caret.layer else { return }
        layer.removeAnimation(forKey: "blink")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.49, 0.5, 1]
        blink.duration = 1
        blink.repeatCount = .infinity
        layer.add(blink, forKey: "blink")
    }

    func updateCaret(text: String, scalarOffset: Int, visible: Bool) {
        let offset = min(max(0, scalarOffset), text.unicodeScalars.count)
        guard caretText != text || caretScalarOffset != offset || caretVisible != visible else { return }
        if caretText != text { clearInputSelection() }
        followCaret = true
        resetCaretBlink()
        caretText = text
        caretScalarOffset = min(max(0, scalarOffset), text.unicodeScalars.count)
        caretVisible = visible
        needsLayout = true
    }

    func updatePromptReady(_ ready: Bool) {
        guard promptReady != ready else { return }
        promptReady = ready
        if !hasInput {
            lineLabel.stringValue = ready ? "Type a command, or ask Agent…" : "Command running…"
            lineLabel.textColor = .secondaryLabelColor
        }
        displayText = lineLabel.stringValue
        inputSymbol.contentTintColor = ready ? SoraTheme.nsAccent : .secondaryLabelColor
        statusLabel.stringValue = ready ? "Ready" : "Running"
        statusLabel.textColor = ready ? SoraTheme.nsAccent : .secondaryLabelColor
        statusLabel.setAccessibilityLabel(ready ? "Terminal ready for a new command" : "Terminal command running")
        hairline.layer?.backgroundColor = (ready
            ? SoraTheme.nsAccent.withAlphaComponent(0.8)
            : NSColor.white.withAlphaComponent(0.25)).cgColor
        // Keep readiness legible even over a bright desktop background.
        effectView.isHidden = true
        layer?.backgroundColor = NSColor(white: 0.065, alpha: 0.98).cgColor
    }

    func updateRoute(_ intent: PromptIntent?) {
        if intent == .agent {
            routeLabel.stringValue = "↵ agent"
            desiredHint = "⌘↵ shell"
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

    func updateBlockBrowsing(_ browsing: Bool) {
        inputClip.alphaValue = browsing ? 0.5 : 1
        statusLabel.stringValue = browsing ? "Browsing" : (promptReady ? "Ready" : "Running")
        statusLabel.setAccessibilityLabel(browsing ? "Command output selected" : statusLabel.stringValue)
        if browsing {
            desiredHint = "↑ ↓  Move between blocks    ·    Return  Use command    ·    Tab  Actions    ·    Esc  Input"
            hintLabel.setAccessibilityLabel(desiredHint)
        }
    }

    func updateHistoryBrowsing(_ browsing: Bool, hasSelection: Bool) {
        // Previewing a long recalled command must not resize/reflow the PTY.
        // Follow its caret within the input's existing visible rows instead.
        if browsing && historyPreviewHeight == nil { historyPreviewHeight = preferredHeight }
        if !browsing && historyPreviewHeight != nil { historyPreviewHeight = nil; needsLayout = true }
        guard browsing else { return }
        statusLabel.stringValue = "History"
        statusLabel.setAccessibilityLabel("Browsing command history")
        if hasSelection { routeLabel.isHidden = true }
        desiredHint = hasSelection ? "Return  Run command" : "Type to keep editing"
        hintLabel.isHidden = false
        hintLabel.setAccessibilityLabel(desiredHint)
    }

    func updateDictation(listening: Bool, transcript: String, error: String?) {
        microphoneButton.image = NSImage(
            systemSymbolName: listening ? "waveform.circle.fill" : "mic",
            accessibilityDescription: listening ? "Stop dictating" : "Dictate"
        )
        microphoneButton.contentTintColor = listening ? SoraTheme.nsAccent : .secondaryLabelColor
        microphoneButton.toolTip = error ?? (listening ? "Stop dictating" : "Dictate into the terminal")
        microphoneButton.setAccessibilityLabel(listening ? "Stop dictating" : "Dictate into the terminal")
        if listening, !transcript.isEmpty {
            lineLabel.stringValue = transcript
            lineLabel.textColor = SoraTheme.nsAccent
        }
        needsLayout = true
    }

    private func applyFallbackHint() {
        if showingPrediction {
            desiredHint = "Tab  Accept suggestion    ·    ↑ ↓  History"
            hintLabel.isHidden = false
            hintLabel.setAccessibilityLabel("Press Tab or Right Arrow to accept prediction")
        } else if agentResumeAvailable {
            desiredHint = "⌘Y continue"
            hintLabel.isHidden = false
            hintLabel.setAccessibilityLabel("Command-Y reopens the agent conversation")
        } else {
            desiredHint = promptReady
                ? (hasInput ? "Return  Run    ·    ⇧Return  New line    ·    ⌘↑  Blocks" : "↑ ↓  History    ·    ⌘↑  Blocks    ·    ⌘⇧A  Agent")
                : "Control-C  Stop command"
            hintLabel.isHidden = false
            hintLabel.setAccessibilityLabel(desiredHint)
        }
    }

    var selectedInputText: String? {
        guard let selectionRange, !selectionRange.isEmpty else { return nil }
        return StickyPromptBarModel.selectedText(caretText, range: selectionRange)
    }

    func clearInputSelection() {
        guard selectionAnchor != nil || selectionRange != nil else { return }
        selectionAnchor = nil
        selectionRange = nil
        needsLayout = true
    }

    private func inputOffset(at point: NSPoint) -> Int? {
        guard promptReady, !showingPrediction, !hitRows.isEmpty else { return nil }
        let row = min(hitRows.count - 1, max(0, Int((inputClip.bounds.height - point.y) / 24)))
        let font = lineLabel.font ?? SoraTheme.terminalFont
        let offset = StickyPromptBarModel.hitOffset(in: hitRows[row].text, x: point.x) {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        return min(caretText.unicodeScalars.count, hitRows[row].start + offset)
    }

    @objc private func selectInput(_ recognizer: NSPanGestureRecognizer) {
        let point = recognizer.location(in: inputClip)
        if recognizer.state == .began {
            let translation = recognizer.translation(in: inputClip)
            let start = NSPoint(x: point.x - translation.x, y: point.y - translation.y)
            guard inputClip.bounds.contains(start) else { return }
            onFocusTerminal?()
            selectionAnchor = inputOffset(at: start)
        }
        guard let anchor = selectionAnchor, let end = inputOffset(at: point) else { return }
        selectionRange = min(anchor, end)..<max(anchor, end)
        needsLayout = true
        if recognizer.state == .ended || recognizer.state == .cancelled { selectionAnchor = nil }
    }

    @objc private func clickInput(_ recognizer: NSClickGestureRecognizer) {
        onFocusTerminal?()
        clearInputSelection()
        let point = recognizer.location(in: inputClip)
        guard inputClip.bounds.contains(point), let offset = inputOffset(at: point) else { return }
        onMoveCursor?(offset)
    }

    @objc private func focusTerminal() {
        onFocusTerminal?()
    }

    @objc private func acceptIfPossible() {
        onAcceptPrediction?()
        onFocusTerminal?()
    }

    @objc private func toggleDictation() {
        onToggleDictation?()
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
        didSet { if oldValue != symbolName { rebuildTitle() } }
    }

    var chipTitle = "" {
        didSet { if oldValue != chipTitle { rebuildTitle() } }
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
