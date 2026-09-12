import AppKit
import CoreText
import GhosttyKit
import os.signpost

protocol GhosttySurfaceDelegate: AnyObject {
    func surfaceDidRequestClose(_ view: GhosttySurfaceView)
    func surfaceDidRequestNewTab(_ view: GhosttySurfaceView)
    func surface(_ view: GhosttySurfaceView, didRequestGotoTab raw: Int32)
    func surface(_ view: GhosttySurfaceView, didRequestCloseTab mode: ghostty_action_close_tab_mode_e)
    func surfaceDidRequestCloseWindow(_ view: GhosttySurfaceView)
    func surface(_ view: GhosttySurfaceView, didChangeTitle title: String)
    func surface(_ view: GhosttySurfaceView, didChangeWorkingDirectory url: URL)
}

/// Plain NSView host for a Ghostty surface. libghostty owns the Metal/IOSurface layer.
final class GhosttySurfaceView: NSView, NSMenuItemValidation {
    private static let inputLog = OSLog(subsystem: "dev.sora.app", category: .pointsOfInterest)
    let runtime: GhosttyRuntime
    let initialWorkingDirectory: URL?
    weak var delegate: GhosttySurfaceDelegate?
    private(set) var surface: ghostty_surface_t?
    private var hasCreatedSurface = false
    private(set) var lastShellTitle = ""
    private(set) var lastWorkingDirectory: URL?
    private(set) var cellSize = NSSize(width: 8, height: 16)
    private let completion = CompletionSession()
    private let commandCompletions = CommandCompletionSession()
    private var completionMenu: CommandCompletionMenu?
    private var completionRequest: CommandCompletionRequest?
    private let ghostText = GhostTextView()
    private var commandHeaderStyles: [String: NSAttributedString] = [:]
    private var commandHeaderFont: NSFont?
    private let commandHeaders = [StickyCommandHeaderView(), StickyCommandHeaderView()]
    private var ghostTextAnchor: GhostTextAnchor?
    private weak var stickyBar: StickyPromptBar?
    private var scrollbarTotal: UInt64 = 0
    private var scrollbarOffset: UInt64 = 0
    private var scrollbarLen: UInt64 = 0
    private var swallowedKeyCodes: Set<UInt16> = []
    private enum StartupInput {
        case keyDown(NSEvent)
        case keyUp(NSEvent)
        case text(String)
    }
    private var startupInput = ShellStartupInputBuffer<StartupInput>()
    private var isShellPromptReady = false
    /// Live ZLE buffer mirrored by the shell. Nil until the first report.
    private var promptContextDirectory: URL?
    private var promptContextBranch: String?
    private var completionRefreshPending = false
    private var shellRecognizesCommand = false
    private var shellEditLine: String?
    private var shellContext: ShellContextReport?
    private var shellContextPID: UInt64?
    private var nativeInputEnabled = false
    private var runningCommand: String?
    private var shellCursorOffset = 0
    private var promptIntent: PromptIntent?
    var onSessionUsed: (() -> Void)?
    var onFocus: (() -> Void)?
    var onCommandStarted: (() -> Void)?
    var onCommandFinished: ((Int16) -> Void)?
    let notificationID = UUID()
    let tabID: UUID
    var onNotificationActivate: (() -> Void)?
    var onBell: (() -> Void)?
    // An immediate quit during shell startup must not replace the restored files
    // with an empty screen or an edit buffer that has not loaded yet.
    var canCheckpointHistory: Bool { surface != nil && !startupInput.isWaiting }
    var draftText: String { isShellPromptReady && !isRemoteSession ? (shellEditLine ?? "") : "" }
    var onAgentPrompt: ((String) -> Void)?
    var onAgentOutput: ((TerminalOutputAttachment) -> Void)?
    var onContinueAgent: (() -> Bool)?
    let commandHistory = CommandHistorySession()
    private var historySearch: CommandHistorySearchController?
    var onHistoryChange: (() -> Void)?
    let blockActions = CommandBlockActionsView()
    private(set) var isBrowsingCommandBlocks = false
    var onBlockSelectionChange: (() -> Void)?
    private var outputMouseDragged = false
    private var handledBlockContextClick = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init(runtime: GhosttyRuntime, tabID: UUID = UUID(), workingDirectory: URL? = nil) {
        self.runtime = runtime
        self.tabID = tabID
        self.initialWorkingDirectory = workingDirectory
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Do not set wantsLayer or install a CAMetalLayer. libghostty assigns the layer.
        ghostText.isHidden = true
        // Layer-back the overlay so it composites in the same space as the
        // libghostty Metal layer instead of drifting in the non-layer path.
        ghostText.wantsLayer = true
        ghostText.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(ghostText)
        commandHeaders.forEach(addSubview)
        commandHistory.onChange = { [weak self] in
            self?.refreshStickyBar()
            self?.onHistoryChange?()
        }
        blockActions.terminal = self
        blockActions.isHidden = true
        blockActions.onKey = { [weak self] in self?.keyDown(with: $0) }
        blockActions.onKeyUp = { [weak self] in self?.keyUp(with: $0) }
        blockActions.onCopyOutput = { [weak self] in self?.copyBlockOutput(nil) }
        blockActions.onReuse = { [weak self] in self?.reuseBlockCommand(nil) }
        blockActions.onReturnToInput = { [weak self] in self?.leaveCommandBlocks() }
        blockActions.makeMenu = { [weak self] in self?.commandBlockMenu() ?? NSMenu() }
    }

    func attachStickyPromptBar(_ bar: StickyPromptBar) {
        stickyBar = bar
        applyShortcuts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        destroySurface()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            // Window chrome (fullSizeContentView, traffic lights in the sidebar)
            // is owned by WindowChromeView. Do not reserve a titlebar strip here.
            window.isOpaque = false
            window.backgroundColor = SoraTheme.nsWindowFill
            window.appearance = TerminalPreferences.appearance.native
            createSurfaceIfNeeded()
            updateSurfaceMetrics()
            setOccluded(isHidden)
        } else {
            dismissCompletionMenu()
            setOccluded(true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceMetrics()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceMetrics()
        refreshCommandHeader()
        // Y is live from IME; refresh so a resize cannot leave ghost text stranded.
        if ghostTextAnchor != nil {
            scheduleCompletionRefresh()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        if became, let surface {
            ghostty_surface_set_focus(surface, true)
            runtime.setFocus(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { dismissCompletionMenu() }
        if resigned, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return resigned
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let interval = OSSignpostID(log: Self.inputLog)
        os_signpost(.begin, log: Self.inputLog, name: "Terminal keyDown", signpostID: interval)
        defer { os_signpost(.end, log: Self.inputLog, name: "Terminal keyDown", signpostID: interval) }
        if startupInput.isWaiting,
           event.modifierFlags.intersection([.control, .command, .option]) == [.control],
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            // Cancellation must remain available even if a startup script hangs.
            startupInput.discardPending()
            swallowedKeyCodes.insert(event.keyCode)
            sendKey(event, action: GHOSTTY_ACTION_PRESS)
            sendKey(event, action: GHOSTTY_ACTION_RELEASE)
            return
        }
        finishStartupForOtherProcessIfNeeded()
        if startupInput.enqueue(.keyDown(event)) { return }
        if replaceSelectedInputIfNeeded(event) { dismissCompletionMenu(); return }
        if handleCompletionMenuKey(event) { return }
        if event.keyCode == PromptEvent.rightArrow,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.option],
           canAcceptCompletionWord {
            acceptNextCompletionWord()
            swallowedKeyCodes.insert(event.keyCode)
            return
        }
        if handleCommandBlockKey(event) { return }
        if handleCommandHistoryKey(event) { return }
        stickyBar?.resetCaretBlink()
        stickyBar?.clearInputSelection()
        captureGhostTextAnchor()
        let characters = event.characters ?? ""
        let isReturn = event.keyCode == PromptEvent.returnKey
            || event.keyCode == PromptEvent.keypadEnter
            || characters == "\r" || characters == "\n"
        // Fullscreen applications own their input; do not query history or the
        // filesystem, rank shell suggestions, or intercept Tab/Right Arrow.
        if !hasLocalEditablePrompt || (!isShellPromptReady && !(isReturn && foregroundProcessIsShell())) {
            if isReturn { isShellPromptReady = false; shellEditLine = nil; setNativeInput(false) }
            completion.stopTracking()
            refreshStickyBar()
            sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            return
        }
        if isReturn && event.modifierFlags.contains(.shift) && isShellPromptReady {
            swallowedKeyCodes.insert(event.keyCode)
            insertText("\n")
            return
        }
        if isReturn {
            onSessionUsed?()
            let forceShell = event.modifierFlags.contains(.command)
            let promptReady = isShellPromptReady || foregroundProcessIsShell()
            // Keystroke tracking clears on arrows / Option-meta / Tab. ZLE still
            // holds the visible line — recover it so conversational Return does
            // not fall through to zsh (e.g. unquoted YouTube URLs).
            let line = promptLineForSubmission()
            let submission = PromptIntentClassifier.submission(
                for: line,
                forceShell: forceShell,
                allowImplicitAgent: promptReady && TerminalPreferences.automaticAgentRouting,
                shellCommandKnown: shellRecognizesCommand && line == shellEditLine
            )
            switch submission {
            case .agent(let question) where !question.isEmpty:
                swallowedKeyCodes.insert(event.keyCode)
                handOffPromptLineToAgent()
                completion.reset()
                shellEditLine = ""
                ghostTextAnchor = nil
                isShellPromptReady = true
                refreshCompletion()
                onAgentPrompt?(question)
                return
            case .shell where forceShell:
                swallowedKeyCodes.insert(event.keyCode)
                sendUnmodifiedReturn(keyCode: event.keyCode)
                completion.reset()
                shellEditLine = ""
                ghostTextAnchor = nil
                isShellPromptReady = false
                refreshCompletion()
                return
            default:
                shellEditLine = ""
                if promptReady {
                    isShellPromptReady = false
                }
            }
        }
        switch completion.handleKeyDown(
            keyCode: event.keyCode,
            characters: characters,
            modifiers: event.modifierFlags
        ) {
        case .accept(let suffix):
            swallowedKeyCodes.insert(event.keyCode)
            refreshCompletion()
            insertText(suffix)
            scheduleCompletionRefresh()
            return
        case .passThrough:
            if let edit = PromptEvent.from(keyCode: event.keyCode, characters: characters,
                                           modifiers: event.modifierFlags),
               edit == .reset || edit == .stopTracking {
                ghostTextAnchor = nil
            }
            sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            scheduleCompletionRefresh()
        }
    }

    override func keyUp(with event: NSEvent) {
        if swallowedKeyCodes.remove(event.keyCode) != nil {
            return
        }
        if startupInput.enqueue(.keyUp(event)) { return }
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        let mods = GhosttyInput.mods(from: event.modifierFlags)
        let mask: UInt32
        switch event.keyCode {
        case 0x39: mask = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mask = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mask = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mask = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mask = GHOSTTY_MODS_SUPER.rawValue
        default:
            return
        }
        let action = (mods.rawValue & mask) != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        sendKey(event, action: action)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if runtime.shortcuts.matches(event) { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        // App-owned command entry points must precede terminal key forwarding.
        if ["a", "p", "r"].contains(chars.lowercased()),
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift] {
            return false
        }
        if [PromptEvent.upArrow, PromptEvent.downArrow].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .option] { return false }
        // Native workspace shortcuts must reach the menu before Ghostty.
        if ["n", "t", "d", "f", "w"].contains(chars.lowercased()),
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            return false
        }
        if chars.lowercased() == "y",
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
           onContinueAgent?() == true {
            return true
        }
        if event.modifierFlags.contains(.command) {
            switch chars {
            case "c":
                copySelectionToPasteboard()
                return true
            case "x" where isShellPromptReady && stickyBar?.hasAllInputSelected == true:
                cut(nil)
                return true
            case "v":
                pasteFromPasteboard()
                return true
            case "a":
                selectAll(nil)
                return true
            default:
                break
            }
        }

        if window?.firstResponder === self,
           event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            keyDown(with: event)
            return true
        }
        return false
    }

    @objc func copy(_ sender: Any?) {
        copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        pasteFromPasteboard()
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        pasteFromPasteboard()
    }

    override func selectAll(_ sender: Any?) {
        acceptCommandHistory()
        if isBrowsingCommandBlocks {
            leaveCommandBlocks(focusInput: false)
            window?.makeFirstResponder(self)
        }
        if isShellPromptReady {
            refreshStickyBar()
            stickyBar?.selectAllInput()
            window?.makeFirstResponder(self)
            return
        }
        performBinding("select_all")
    }

    @objc func cut(_ sender: Any?) {
        guard isShellPromptReady, stickyBar?.hasAllInputSelected == true else { return }
        copySelectionToPasteboard()
        stickyBar?.clearInputSelection()
        stageShellCommand("")
    }

    /// The preview owns selection; ZLE still owns editing and execution.
    private func replaceSelectedInputIfNeeded(_ event: NSEvent) -> Bool {
        guard isShellPromptReady, stickyBar?.hasAllInputSelected == true else { return false }
        guard let replacement = StickyPromptBarModel.selectionReplacement(
            keyCode: event.keyCode, text: event.characters ?? "", modifiers: event.modifierFlags
        ) else { return false }
        stickyBar?.clearInputSelection()
        stageShellCommand(replacement)
        swallowedKeyCodes.insert(event.keyCode)
        return true
    }

    func copySelectionToPasteboard() {
        if let text = stickyBar?.selectedInputText {
            GhosttyClipboard.writePlainText(text, to: .general)
            return
        }
        guard let surface, ghostty_surface_has_selection(surface) else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0, let bytes = text.text else { return }
        let value = String(
            decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(bytes), count: Int(text.text_len)),
            as: UTF8.self
        )
        GhosttyClipboard.writePlainText(value, to: .general)
    }

    var usesBinaryImagePaste: Bool { !isShellPromptReady }

    func insertDroppedImages(_ files: [URL]) throws {
        guard !isRemoteSession else { throw TerminalImageDrop.DropError.remoteTransferRequired }
        if usesBinaryImagePaste {
            guard files.count == 1, let image = files.first else { throw TerminalImageDrop.DropError.multipleImages }
            try GhosttyClipboard.writeImage(at: image, to: .general)
            pasteClipboardImageIntoProgram()
            return
        }
        let paths = try files.map(TerminalImageDrop.quotedPath)
        guard surface != nil, !paths.isEmpty else { return }
        leaveCommandBlocks()
        acceptCommandHistory()
        window?.makeFirstResponder(self)
        for path in paths {
            captureGhostTextAnchor()
            completion.handlePaste(path)
            // ghostty_surface_text uses bracketed paste when the foreground
            // application requests it. Each image gets its own paste boundary.
            insertText(path)
        }
        refreshCompletion()
        scheduleCompletionRefresh()
    }

    func pasteFromPasteboard() {
        dismissCompletionMenu()
        guard surface != nil else { return }
        if isRemoteSession, GhosttyClipboard.hasImage(in: .general) {
            NSAlert(error: TerminalImageDrop.DropError.remoteTransferRequired).runModal()
            return
        }
        if usesBinaryImagePaste, GhosttyClipboard.hasImage(in: .general) {
            pasteClipboardImageIntoProgram()
            return
        }
        guard let value = GhosttyClipboard.plainText(from: .general), !value.isEmpty else { return }
        leaveCommandBlocks()
        acceptCommandHistory()
        if isShellPromptReady, stickyBar?.hasAllInputSelected == true {
            stickyBar?.clearInputSelection()
            stageShellCommand(value)
            return
        }
        captureGhostTextAnchor()
        completion.handlePaste(value)
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) { ghostTextAnchor = nil }
        refreshCompletion()
        insertText(value)
        scheduleCompletionRefresh()
    }

    private func pasteClipboardImageIntoProgram() {
        leaveCommandBlocks()
        acceptCommandHistory()
        window?.makeFirstResponder(self)
        // Ctrl-V asks the foreground CLI to read the image from the native
        // clipboard. No binary bytes, base64, file paths, or Return enter the PTY.
        sendControlKey(keyCode: 9, unshifted: UnicodeScalar("v"))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cut(_:)):
            return isShellPromptReady && stickyBar?.hasAllInputSelected == true
        case #selector(copy(_:)):
            if stickyBar?.selectedInputText != nil { return true }
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        default:
            return true
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        dismissCompletionMenu()
        outputMouseDragged = false
        dismissCommandHistory()
        leaveCommandBlocks(focusInput: false)
        stickyBar?.clearInputSelection()
        window?.makeFirstResponder(self)
        // Focusing a ready prompt must not kill AI routing. Clicks used to
        // stop tracking whenever text was present, which sent conversational
        // lines (with URLs) to zsh. Arrow/control edits still stopTracking.
        applyPromptMouseFocus()
        ghostTextAnchor = nil
        ghostText.hide()
        refreshCompletion()
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    func applyStickyBarFocus() {
        dismissCompletionMenu()
        acceptCommandHistory()
        leaveCommandBlocks()
        window?.makeFirstResponder(self)
        reassertTerminalFocus()
        applyPromptMouseFocus()
        refreshCompletion()
    }

    func insertDictatedText(_ value: String) {
        guard !value.isEmpty else { return }
        leaveCommandBlocks()
        acceptCommandHistory()
        captureGhostTextAnchor()
        completion.handlePaste(value)
        refreshCompletion()
        insertText(value)
        scheduleCompletionRefresh()
    }

    private func applyPromptMouseFocus() {
        completion.applyMouseFocus(isShellPromptReady: isShellPromptReady)
    }

    /// The shell's own edit buffer wins whenever it has reported one: it stays
    /// correct through paste, history recall, completion, and wrapping. The
    /// keystroke buffer is the fallback for shells without the Sora hooks.
    private func promptLineForSubmission() -> String {
        if let shellEditLine {
            return shellEditLine
        }
        return completion.buffer.isTracking ? completion.buffer.text : ""
    }

    override func mouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        if !outputMouseDragged, event.clickCount == 1,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            selectCommandBlock(at: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !isBrowsingCommandBlocks, let surface, ghostty_surface_has_selection(surface) {
            handledBlockContextClick = true
            let menu = NSMenu(title: "Selected Output")
            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            let ask = NSMenuItem(title: "Ask Agent About Selection…", action: #selector(askAboutOutput(_:)), keyEquivalent: "")
            ask.target = self
            menu.addItem(ask)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        handledBlockContextClick = selectCommandBlock(at: event)
        if handledBlockContextClick {
            NSMenu.popUpContextMenu(commandBlockMenu(), with: event, for: self)
            return
        }
        leaveCommandBlocks(focusInput: false)
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        if handledBlockContextClick {
            handledBlockContextClick = false
            return
        }
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func mouseDragged(with event: NSEvent) {
        outputMouseDragged = true
        sendMousePosition(event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Convert a positive unit size: AppKit standardizes negative sizes,
            // which would turn downward gestures into upward scrolling.
            let scale = convertToBacking(NSSize(width: 1, height: 1))
            deltaX *= scale.width
            deltaY *= scale.height
        }
        ghostty_surface_mouse_scroll(
            surface,
            deltaX,
            deltaY,
            GhosttyInput.scrollMods(precision: event.hasPreciseScrollingDeltas)
        )
        // Scrollbar action arrives async; refresh after the tick so overlays
        // hide while the live prompt is off-screen.
        scheduleCompletionRefresh()
    }

    func applyScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        scrollbarTotal = total
        scrollbarOffset = offset
        scrollbarLen = len
        if isBrowsingCommandBlocks, let surface, !ghostty_surface_has_selection(surface) {
            leaveCommandBlocks()
        }
        refreshCompletion()
    }

    // MARK: - Lifecycle

    private var findPanel: TerminalFindPanel?
    func showFind(scope: OutputSearchScope? = nil, query: String? = nil) {
        if findPanel == nil { findPanel = TerminalFindPanel(surface: self) }
        findPanel?.show(scope: scope ?? (isBrowsingCommandBlocks ? .selectedBlock : .terminal), query: query ?? selectedTextForFind())
    }
    func updateFindCount(_ count: Int) { findPanel?.setCount(count) }
    func updateFindSelection(_ index: Int) { findPanel?.setSelected(index) }
    func searchOutput(_ query: String) { performBinding("search:" + query) }
    func navigateFind(previous: Bool) { performBinding("navigate_search:" + (previous ? "previous" : "next")) }
    func endFind() { performBinding("end_search") }
    private func selectedTextForFind() -> String? {
        guard !isBrowsingCommandBlocks, let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return nil }
        var data = Data(UnsafeRawBufferPointer(start: bytes, count: min(Int(text.text_len), 4096)))
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        let value = String(decoding: data, as: UTF8.self)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }
    func captureOutputSearchSnapshot(scope: OutputSearchScope) -> OutputSearchSnapshot? {
        if scope == .selectedBlock {
            guard isBrowsingCommandBlocks, let command = readCommandBlock(command: true) else { return nil }
            return OutputSearchSnapshot(text: readCommandBlock(command: false) ?? "", command: command)
        }
        return plainHistoryText().map { OutputSearchSnapshot(text: $0) }
    }
    var hasRunningTask: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }
    var historyArchiveURL: URL?

    private var isExportingHistory = false
    private var exportedHistory: String?

    /// Ghostty returns an export filename through its clipboard callback.
    /// Capture it synchronously without modifying the user's clipboard.
    func captureHistoryExport(_ path: String) -> Bool {
        guard isExportingHistory else { return false }
        let url = URL(fileURLWithPath: path)
        do {
            exportedHistory = try String(contentsOf: url, encoding: .utf8)
            try FileManager.default.removeItem(at: url)
        } catch { NSLog("Could not read terminal color history: %@", error.localizedDescription) }
        return true
    }

    func historyText() -> String? {
        guard let surface else { return nil }
        var history = ghostty_text_s()
        if ghostty_surface_read_command_history(surface, &history) {
            defer { ghostty_surface_free_text(surface, &history) }
            guard let bytes = history.text else { return "" }
            let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(history.text_len)), as: UTF8.self)
            return TerminalHistoryArchive.preparingGhosttyExport(text, promptReady: isShellPromptReady)
        }
        NSLog("Could not capture command boundaries; falling back to styled terminal history")
        isExportingHistory = true
        exportedHistory = nil
        let action = "write_screen_file:copy,vt"
        let accepted = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        isExportingHistory = false
        if accepted, let exportedHistory { return exportedHistory }
        return plainHistoryText()
    }

    private func plainHistoryText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return nil }
        return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self)
    }

    private func createSurfaceIfNeeded() {
        guard !hasCreatedSurface, window != nil else { return }
        hasCreatedSurface = true

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.font_size = Float(TerminalPreferences.fontSize)
        config.command = nil
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB

        let zdotdir = SoraZshBootstrap.defaultDirectory().path
        let created: ghostty_surface_t? = "ZDOTDIR".withCString { keyPtr in
            zdotdir.withCString { valuePtr in
                "SORA_RESTORE_HISTORY".withCString { historyKey in
                    (historyArchiveURL?.path ?? "").withCString { historyValue in
                var env = [ghostty_env_var_s(key: keyPtr, value: valuePtr), ghostty_env_var_s(key: historyKey, value: historyValue)]
                return env.withUnsafeMutableBufferPointer { envPtr in
                    config.env_vars = envPtr.baseAddress
                    config.env_var_count = 2
                    if let initialWorkingDirectory {
                        return initialWorkingDirectory.path.withCString { pointer in
                            config.working_directory = pointer
                            return ghostty_surface_new(runtime.app, &config)
                        }
                    }
                    config.working_directory = nil
                    return ghostty_surface_new(runtime.app, &config)
                }
                    }
                }
            }
        }

        guard let created else {
            assertionFailure("ghostty_surface_new failed")
            return
        }
        surface = created
        // Surface creation starts the shell asynchronously. Until its first
        // edit-line report, PTY echo can print input above the real prompt.
        isShellPromptReady = false
        runtime.activeSurface = self
        runtime.tick()
        updateSurfaceMetrics()
        ghostty_surface_set_focus(created, true)
        ghostty_surface_set_occlusion(created, true)
    }

    func setActive(_ active: Bool, visible: Bool? = nil) {
        isHidden = !(visible ?? active)
        setOccluded(!(visible ?? active))
        if active {
            runtime.activeSurface = self
            updateSurfaceMetrics()
            window?.makeFirstResponder(isBrowsingCommandBlocks ? blockActions : self)
            // makeFirstResponder is a no-op when we are already first responder,
            // so always re-assert Ghostty focus after un-occlusion. Leaving the
            // agent overlay clears focus via occlusion; without this the blink
            // shader sees iFocus=0 and custom-shader-animation never runs.
            reassertTerminalFocus()
        } else {
            dismissCompletionMenu()
            dismissCommandHistory()
            ghostText.hide()
            if runtime.activeSurface === self {
                runtime.activeSurface = nil
            }
        }
    }

    /// Tell libghostty the surface is focused so the cursor blink shader animates.
    func reassertTerminalFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, true)
        runtime.setFocus(true)
    }

    func closeSession() {
        destroySurface()
    }

    private var foregroundExecutable: String? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0, pid <= UInt64(pid_t.max) else { return nil }
        return ForegroundWorkingDirectory.executableName(pid: pid_t(pid))
    }

    var isRemoteSession: Bool {
        ShellContextReport.isRemote(report: shellContext, foreground: foregroundExecutable,
            reportedPID: shellContextPID, foregroundPID: surface.map(ghostty_surface_foreground_pid))
    }
    private var hasLocalEditablePrompt: Bool { !isRemoteSession && shellEditLine != nil }
    private var contextLabel: String? { isRemoteSession ? ShellContextReport.displayRemote(report: shellContext) : nil }

    private func setNativeInput(_ enabled: Bool) {
        guard nativeInputEnabled != enabled else { return }
        nativeInputEnabled = enabled
        if let surface { ghostty_surface_set_native_input(surface, enabled) }
    }

    @discardableResult
    func allowLocalAgent() -> Bool {
        guard isRemoteSession else { return true }
        let alert = NSAlert()
        alert.messageText = "Agent works in a local terminal"
        alert.informativeText = "This tab is connected to a remote shell. Open a local tab to use Agent; commands here continue to run in the remote shell."
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        return false
    }

    func currentWorkingDirectory() -> URL? {
        guard !isRemoteSession, let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0, pid <= UInt64(pid_t.max) else { return nil }
        return ForegroundWorkingDirectory.url(pid: pid_t(pid))
    }

    private func foregroundProcessIsShell() -> Bool {
        guard let surface else { return false }
        let rawPID = ghostty_surface_foreground_pid(surface)
        guard rawPID > 0, rawPID <= UInt64(pid_t.max),
              let name = ForegroundWorkingDirectory.executableName(pid: pid_t(rawPID))
        else { return false }
        return ["zsh", "bash", "fish", "sh"].contains(name)
    }

    private var titleAssembler = ShellTitleAssembler()

    func applyTitle(_ title: String) {
        guard let title = titleAssembler.consume(title) else { return }
        if title.hasPrefix(ShellContextReport.prefix) {
            guard let report = ShellContextReport.parse(title) else { return }
            shellContext = report
            shellContextPID = surface.map(ghostty_surface_foreground_pid)
            promptContextDirectory = nil
            promptContextBranch = nil
            if report.shell != "zsh" { shellEditLine = nil; setNativeInput(false) }
            if report.isRemote || isRemoteSession {
                completion.stopTracking()
                dismissCompletionMenu()
                dismissCommandHistory()
                refreshStickyBar()
            } else { applyWorkingDirectory(report.path) }
            return
        }
        if let command = ShellEditLine.startedCommand(title: title) {
            setNativeInput(false)
            dismissCompletionMenu()
            onSessionUsed?()
            if !isRemoteSession { runningCommand = command.isEmpty ? nil : command }
            if !command.isEmpty { onCommandStarted?() }
            dismissCommandHistory()
            leaveCommandBlocks(focusInput: false)
            isShellPromptReady = false
            shellEditLine = nil
            shellRecognizesCommand = false
            promptIntent = nil
            completion.stopTracking()
            ghostText.hide()
            refreshStickyBar()
            return
        }
        // zsh mirrors its live edit buffer through a sentinel title. Consume it
        // as routing state; it is never a window or tab title.
        if let line = ShellEditLine.parse(title: title) {
            if !isShellPromptReady { completion.reset() }
            shellRecognizesCommand = ShellEditLine.shellRecognizesCommand(title: title)
            shellEditLine = line
            setNativeInput(true)
            shellCursorOffset = ShellEditLine.cursorOffset(title: title) ?? line.unicodeScalars.count
            // Only ZLE emits this, so the shell is definitionally at a prompt.
            isShellPromptReady = true
            // Arrives on every redraw; avoid the history/path work in a full refresh.
            refreshPromptRoute()
            refreshStickyBar()
            finishStartupInput()
            return
        }
        lastShellTitle = title
        let value = title.isEmpty ? "Sora" : title
        if runtime.activeSurface === self {
            window?.title = value
        }
        runtime.applyTitle(value)
        delegate?.surface(self, didChangeTitle: value)
    }

    func applyWorkingDirectory(_ path: String) {
        guard !isRemoteSession, path.hasPrefix("/") else { refreshStickyBar(); return }
        let url = URL(fileURLWithPath: path)
        promptContextDirectory = nil
        lastWorkingDirectory = url
        // Ghostty's zsh integration emits OSC 7 while presenting a prompt.
        // Treat that signal as authoritative readiness too: some embedded
        // builds don't deliver COMMAND_FINISHED reliably, leaving routing
        // permanently disabled after the first shell submission.
        if !isShellPromptReady {
            isShellPromptReady = true
            completion.reset()
            ghostTextAnchor = nil
            refreshCompletion()
        } else {
            refreshStickyBar()
        }
        // Other shells do not emit Sora's ZLE edit-line report. Their shell
        // integration's prompt directory report is the readiness signal.
        finishStartupForOtherProcessIfNeeded()
        delegate?.surface(self, didChangeWorkingDirectory: url)
    }

    func recordCommandFinished(exitCode: Int16, durationNanos: UInt64) {
        dismissCommandHistory()
        onCommandFinished?(exitCode)
        isShellPromptReady = true
        shellEditLine = nil
        guard !isRemoteSession else {
            completion.stopTracking()
            refreshStickyBar()
            return
        }
        let cwd = lastWorkingDirectory ?? currentWorkingDirectory() ?? initialWorkingDirectory
        let run = runtime.recordCommand(
            tabID: tabID,
            command: runningCommand ?? (shellContext?.shell == "bash" ? "" : lastShellTitle),
            cwd: cwd,
            exitCode: exitCode,
            durationNanos: durationNanos
        )
        if let run { runtime.notifications.commandFinished(run, from: self) }
        runningCommand = nil
        completion.reset()
        ghostTextAnchor = nil
        if let run, run.exitCode == 0 {
            if let previous = completion.lastSuccessfulCommand {
                runtime.recordTransition(
                    previous: previous,
                    next: run.command,
                    cwd: run.cwd,
                    at: run.finishedAt
                )
            }
            completion.rememberSuccessfulCommand(run.command)
        }
        scheduleCompletionRefresh()
    }

    var canRunAgentCommand: Bool {
        hasLocalEditablePrompt && isShellPromptReady && completion.buffer.isTracking && completion.buffer.text.isEmpty
    }

    @discardableResult
    func runApprovedCommand(_ command: String) -> Bool {
        guard canRunAgentCommand, AgentCommandProposal.isValidCommand(command) else { return false }
        insertText(command)
        completion.reset()
        ghostTextAnchor = nil
        promptIntent = nil
        isShellPromptReady = false
        refreshCompletion()
        sendUnmodifiedReturn(keyCode: PromptEvent.returnKey)
        return true
    }

    func applyCellSize(backingWidth: UInt32, backingHeight: UInt32) {
        let backing = NSSize(width: CGFloat(backingWidth), height: CGFloat(backingHeight))
        let converted = convertFromBacking(backing)
        if converted.width > 0, converted.height > 0 {
            cellSize = converted
        }
    }

    func requestClose() {
        delegate?.surfaceDidRequestClose(self)
    }

    func requestNewTab() {
        delegate?.surfaceDidRequestNewTab(self)
    }

    func requestGotoTab(_ raw: Int32) {
        delegate?.surface(self, didRequestGotoTab: raw)
    }

    func requestCloseTab(_ mode: ghostty_action_close_tab_mode_e) {
        delegate?.surface(self, didRequestCloseTab: mode)
    }

    func requestCloseWindow() {
        delegate?.surfaceDidRequestCloseWindow(self)
    }

    private func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
        if occluded {
            ghostty_surface_set_focus(surface, false)
        }
    }

    private func destroySurface() {
        findPanel?.dismiss(returnFocus: false)
        findPanel = nil
        ghostText.hide()
        guard let surface else { return }
        if runtime.activeSurface === self {
            runtime.activeSurface = nil
        }
        self.surface = nil
        hasCreatedSurface = false
        ghostty_surface_free(surface)
    }

    private func updateSurfaceMetrics() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let backing = convertToBacking(bounds)
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
        if let window {
            let scale = Double(window.backingScaleFactor)
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
    }

    private func finishStartupForOtherProcessIfNeeded() {
        guard startupInput.isWaiting, let surface else { return }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0, pid <= UInt64(pid_t.max),
              let name = ForegroundWorkingDirectory.executableName(pid: pid_t(pid)),
              name != "zsh", name != "login" else { return }
        // Do not require ZLE from another shell or an interactive program
        // launched by a startup file (for example, an authentication prompt).
        finishStartupInput()
    }

    private func finishStartupInput() {
        for input in startupInput.finish() {
            switch input {
            case .keyDown(let event): keyDown(with: event)
            case .keyUp(let event): keyUp(with: event)
            case .text(let value): insertText(value)
            }
        }
    }

    private func insertText(_ value: String) {
        guard !value.isEmpty else { return }
        finishStartupForOtherProcessIfNeeded()
        if startupInput.enqueue(.text(value)) { return }
        guard let surface else { return }
        value.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(value.utf8.count))
        }
        runtime.tick()
    }

    /// Clear the line Sora just handed to the agent. When Sora's zsh
    /// integration is loaded its widget also closes the block with a rule, so
    /// scrollback delineates an agent prompt the same way it delineates a
    /// command run. A mirrored edit line is proof the integration is present.
    private func handOffPromptLineToAgent() {
        guard shellEditLine != nil else {
            // Cancel zsh's entire edit buffer. A kill-line widget depends on
            // ZLE's transient cursor during redraw and can leave a suffix
            // behind; terminal interrupt cannot submit it.
            cancelPromptLine()
            return
        }
        // Ctrl+6 encodes as ASCII RS (0x1E), which command-blocks.zsh binds.
        // A bare unshifted_codepoint of 0x1E writes nothing: Ghostty only emits
        // C0 bytes through ctrlSeq when the control modifier is set.
        sendControlKey(keyCode: 0x16, unshifted: UnicodeScalar("6"), text: "6")
    }

    /// Send an actual Control-C key event. `ghostty_surface_text` is for text
    /// input and intentionally does not encode C0 control bytes for zsh.
    private func cancelPromptLine() {
        sendControlKey(keyCode: 8, unshifted: UnicodeScalar("c"))
    }

    func moveShellCursor(to offset: Int) {
        acceptCommandHistory()
        guard isShellPromptReady, let line = shellEditLine, let surface else { return }
        let target = min(max(0, offset), line.unicodeScalars.count)
        let delta = target - shellCursorOffset
        guard delta != 0 else { return }
        completion.stopTracking()
        var key = ghostty_input_key_s()
        key.keycode = delta < 0 ? 123 : 124
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        for _ in 0..<abs(delta) {
            key.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, key)
            key.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, key)
        }
        runtime.tick()
    }

    private func sendControlKey(
        keyCode: UInt32,
        unshifted: UnicodeScalar,
        text: String? = nil
    ) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.keycode = keyCode
        key.mods = GHOSTTY_MODS_CTRL
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = unshifted.value
        key.composing = false
        let fire = {
            key.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, key)
            key.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, key)
        }
        if let text {
            // Keep the C string alive for both press and release.
            text.withCString { pointer in
                key.text = pointer
                fire()
            }
        } else {
            key.text = nil
            fire()
        }
        runtime.tick()
    }

    /// Command-Return is an app-level routing override. Submit the line to the
    /// shell as a plain Return so zsh does not receive the Command modifier.
    private func sendUnmodifiedReturn(keyCode: UInt16) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32(keyCode)
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 13
        key.composing = false
        key.text = nil
        _ = ghostty_surface_key(surface, key)
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
        runtime.tick()
    }

    private func scheduleCompletionRefresh() {
        guard !completionRefreshPending else { return }
        completionRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.completionRefreshPending = false
            self.refreshCompletion()
        }
    }

    /// Called from libghostty's wakeup after PTY output moves the cursor.
    func scheduleCompletionRefreshFromTerminal() {
        scheduleCompletionRefresh()
    }

    /// Recomputes only the shell/agent route label for the current line.
    private func displayIntent(for line: String) -> PromptIntent {
        guard hasLocalEditablePrompt else { return .shell }
        switch PromptIntentClassifier.submission(for: line, allowImplicitAgent: TerminalPreferences.automaticAgentRouting,
                                                shellCommandKnown: shellRecognizesCommand && line == shellEditLine,
                                                commandExists: { _ in line == shellEditLine ? shellRecognizesCommand : true }) {
        case .shell: return .shell
        case .agent: return .agent
        }
    }

    private func refreshPromptRoute() {
        let line = promptLineForSubmission()
        promptIntent = isShellPromptReady && !line.isEmpty
            ? displayIntent(for: line)
            : nil
        stickyBar?.updateRoute(promptIntent)
    }

    private func refreshCompletion() {
        refreshCommandHeader()
        guard isShellPromptReady, hasLocalEditablePrompt else {
            completion.stopTracking()
            ghostText.hide()
            refreshStickyBar()
            return
        }
        let cwd = lastWorkingDirectory
            ?? currentWorkingDirectory()
            ?? initialWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        completion.refreshAsync(cwd: cwd, history: runtime.history) { [weak self] in
            self?.refreshStickyBar()
        }
        // Show the route from whatever line Return would actually submit.
        let routableLine = promptLineForSubmission()
        let route = isShellPromptReady && !routableLine.isEmpty
            ? displayIntent(for: routableLine)
            : nil
        promptIntent = route
        refreshStickyBar()

        ghostText.hide()
    }

    private func captureGhostTextAnchor() {
        guard completion.buffer.isTracking, completion.buffer.text.isEmpty,
              ghostTextAnchor == nil, let surface else { return }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let cellWidth = cellSize.width > 0 ? cellSize.width : 8
        let origin = GhosttyInput.ghostTextOrigin(
            imeX: x, imeY: y, viewHeight: bounds.height, cellWidth: cellWidth
        )
        ghostTextAnchor = GhostTextAnchor(
            originX: origin.x,
            cellWidth: cellWidth
        )
    }

    private func refreshStickyBar() {
        guard let stickyBar else { return }
        let cwd = isRemoteSession ? nil : (lastWorkingDirectory
            ?? currentWorkingDirectory()
            ?? initialWorkingDirectory)
        let path = contextLabel ?? StickyPromptBarModel.displayPath(for: cwd)
        if promptContextDirectory != cwd {
            promptContextDirectory = cwd
            promptContextBranch = cwd.flatMap { GitRepository.branchName(containing: $0) }
        }
        let branch = promptContextBranch
        let historyPreview = commandHistory.isPresented ? commandHistory.selected?.command : nil
        let suggestion = commandHistory.isPresented || !hasLocalEditablePrompt ? nil : completion.suggestion
        let buffer = historyPreview ?? shellEditLine ?? completion.buffer.text
        let predicted = isShellPromptReady && buffer.isEmpty && suggestion?.source == .prediction
        let line: String? = isShellPromptReady
            ? StickyPromptBarModel.inputText(buffer: buffer, prediction: predicted ? suggestion?.displayText : nil)
            : nil
        stickyBar.update(
            path: path,
            directory: cwd,
            branch: branch,
            line: line,
            predicted: predicted
        )
        stickyBar.updateCaret(text: buffer, scalarOffset: historyPreview == nil ? shellCursorOffset : buffer.unicodeScalars.count,
                              visible: isShellPromptReady && !isBrowsingCommandBlocks)
        stickyBar.updatePromptReady(isShellPromptReady)
        stickyBar.updateRoute(historyPreview == nil ? promptIntent : .shell)
        let validSuffix = completion.buffer.isTracking && completion.buffer.text == buffer
            && shellCursorOffset == buffer.unicodeScalars.count && !buffer.isEmpty
            && suggestion?.source != .prediction && promptIntent != .agent
        stickyBar.updateSuggestion(validSuffix ? suggestion?.insertSuffix : nil,
                                   acceptsWord: validSuffix && completion.nextWordSuffix != nil)
        stickyBar.updateBlockBrowsing(isBrowsingCommandBlocks)
        stickyBar.updateHistoryBrowsing(commandHistory.isPresented, hasSelection: historyPreview != nil)
        stickyBar.updateShellInput(mirrored: shellEditLine != nil, remote: isRemoteSession)
    }

    // MARK: - Command history in the input

    private func handleCommandHistoryKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == [.control], event.keyCode == 15, canSearchHistory {
            showHistorySearch()
            swallowedKeyCodes.insert(event.keyCode)
            return true
        }
        if commandHistory.isPresented {
            if mods.isEmpty {
                switch event.keyCode {
                case PromptEvent.upArrow, PromptEvent.downArrow:
                    commandHistory.move(older: event.keyCode == PromptEvent.upArrow)
                case PromptEvent.escape:
                    dismissCommandHistory()
                case PromptEvent.tab:
                    acceptCommandHistory()
                case PromptEvent.returnKey, PromptEvent.keypadEnter:
                    // A recalled command is explicitly a shell command. Do not
                    // route it through the optional conversational classifier.
                    if commandHistory.selected == nil {
                        if commandHistory.isLoading {
                            swallowedKeyCodes.insert(event.keyCode)
                            return true
                        }
                        dismissCommandHistory()
                        return false
                    }
                    acceptCommandHistory()
                    isShellPromptReady = false
                    completion.reset()
                    shellEditLine = ""
                    refreshStickyBar()
                    sendUnmodifiedReturn(keyCode: event.keyCode)
                default:
                    acceptCommandHistory()
                    return false
                }
                swallowedKeyCodes.insert(event.keyCode)
                return true
            }
            if mods == [.control] && (event.characters == "\u{03}" || event.characters?.lowercased() == "c") {
                dismissCommandHistory()
            } else {
                acceptCommandHistory()
            }
            return false
        }
        guard window?.firstResponder === self,
              !isBrowsingCommandBlocks, hasLocalEditablePrompt,
              CommandHistoryInput.opensHistory(
                keyCode: event.keyCode, modifiers: event.modifierFlags,
                promptReady: isShellPromptReady, hasShellIntegration: shellEditLine != nil,
                draft: promptLineForSubmission(), cursorOffset: shellCursorOffset
              ) else { return false }
        stickyBar?.clearInputSelection()
        performBinding("scroll_to_bottom")
        let store = runtime.history
        let tabID = self.tabID
        commandHistory.open(draft: promptLineForSubmission()) { try store.recall(prefix: $0, tabID: tabID) }
        swallowedKeyCodes.insert(event.keyCode)
        return true
    }

    func dismissCommandHistory() { commandHistory.dismiss() }

    func chooseHistoryCommand(at index: Int) {
        commandHistory.select(index: index)
        acceptCommandHistory()
        window?.makeFirstResponder(self)
    }

    var canInsertCommandForEditing: Bool { isShellPromptReady && hasLocalEditablePrompt }
    var canSearchHistory: Bool { canInsertCommandForEditing && !isBrowsingCommandBlocks }

    func showHistorySearch() {
        guard canSearchHistory, let window, window.attachedSheet == nil else { return }
        dismissCommandHistory()
        let picker = CommandHistorySearchController(store: runtime.history, tabID: tabID,
            directory: currentWorkingDirectory() ?? initialWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
        historySearch = picker
        picker.onFinish = { [weak self] command in
            guard let self else { return }
            self.historySearch = nil
            self.window?.makeFirstResponder(self)
            if let command, self.canSearchHistory { self.stageShellCommand(command) }
        }
        picker.present(in: window)
    }

    private func acceptCommandHistory() {
        guard commandHistory.isPresented else { return }
        let command = commandHistory.selected?.command
        commandHistory.dismiss()
        guard isShellPromptReady, let command else { return }
        stageShellCommand(command)
    }

    func insertCommandForEditing(_ command: String) {
        guard canInsertCommandForEditing else { NSSound.beep(); return }
        dismissCommandHistory()
        if isBrowsingCommandBlocks { leaveCommandBlocks() }
        window?.makeFirstResponder(self)
        stageShellCommand(command)
    }

    private func stageShellCommand(_ command: String) {
        // The existing ZLE widget replaces the whole buffer, including newlines.
        // Paste treats the recalled command as data; only Return can execute it.
        sendControlKey(keyCode: 7, unshifted: UnicodeScalar("x"))
        sendControlKey(keyCode: 15, unshifted: UnicodeScalar("r"))
        completion.reset()
        completion.handlePaste(command)
        insertText(command)
        shellEditLine = command
        shellCursorOffset = command.unicodeScalars.count
        shellRecognizesCommand = false
        refreshStickyBar()
        scheduleCompletionRefresh()
    }

    // MARK: - Contextual command completions

    private var canAcceptCompletionWord: Bool {
        canInsertCommandForEditing && !isBrowsingCommandBlocks && !commandHistory.isPresented
            && shellEditLine == completion.buffer.text
            && shellCursorOffset == completion.buffer.text.unicodeScalars.count
            && promptIntent != .agent && completion.nextWordSuffix != nil
    }

    func acceptNextCompletionWord() {
        guard canAcceptCompletionWord, let suffix = completion.acceptNextWord() else { NSSound.beep(); return }
        dismissCompletionMenu()
        shellEditLine = completion.buffer.text
        shellCursorOffset = completion.buffer.text.unicodeScalars.count
        insertText(suffix)
        refreshCompletion()
        scheduleCompletionRefresh()
    }

    func showCommandCompletions() {
        guard requestCommandCompletions(autoAcceptSingle: false) else {
            if canInsertCommandForEditing && !isBrowsingCommandBlocks { sendShellCompletionTab() }
            return
        }
    }

    private func handleCompletionMenuKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let menu = completionMenu, modifiers.isEmpty {
            switch event.keyCode {
            case PromptEvent.upArrow: menu.move(-1)
            case PromptEvent.downArrow: menu.move(1)
            case PromptEvent.tab, PromptEvent.returnKey: menu.accept()
            case PromptEvent.escape: dismissCompletionMenu()
            default: dismissCompletionMenu(); return false
            }
            swallowedKeyCodes.insert(event.keyCode)
            return true
        }
        if commandCompletions.isPending || completionMenu != nil {
            dismissCompletionMenu()
            if modifiers.isEmpty, event.keyCode == PromptEvent.escape {
                swallowedKeyCodes.insert(event.keyCode)
                return true
            }
        }
        guard modifiers.isEmpty, event.keyCode == PromptEvent.tab, !commandHistory.isPresented,
              requestCommandCompletions(autoAcceptSingle: true) else { return false }
        swallowedKeyCodes.insert(event.keyCode)
        return true
    }

    @discardableResult
    private func requestCommandCompletions(autoAcceptSingle: Bool) -> Bool {
        guard canInsertCommandForEditing, !isBrowsingCommandBlocks, let line = shellEditLine,
              shellCursorOffset == line.unicodeScalars.count else { return false }
        let directory = currentWorkingDirectory() ?? initialWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        guard let request = CommandCompletionRequest.parse(line: line, directory: directory) else { return false }
        dismissCompletionMenu()
        completionRequest = request
        commandCompletions.request(request) { [weak self] result in
            guard let self, self.completionRequest == request,
                  self.canInsertCommandForEditing, self.shellEditLine == request.line,
                  self.shellCursorOffset == request.line.unicodeScalars.count,
                  self.window?.firstResponder === self,
                  (self.currentWorkingDirectory() ?? self.initialWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser) == request.directory
            else { return }
            switch result {
            case .success(let choices) where choices.isEmpty:
                self.dismissCompletionMenu()
                self.sendShellCompletionTab()
            case .success(let choices) where choices.count == 1 && autoAcceptSingle:
                self.acceptCommandCompletion(choices[0], request: request)
            default:
                let menu = CommandCompletionMenu()
                self.completionMenu = menu
                menu.onChoose = { [weak self] choice in self?.acceptCommandCompletion(choice, request: request) }
                menu.onCancel = { [weak self] in self?.dismissCompletionMenu() }
                menu.onShellCompletion = { [weak self] in
                    self?.dismissCompletionMenu()
                    self?.sendShellCompletionTab()
                }
                switch result {
                case .success(let choices): menu.present(choices: choices, above: self.stickyBar ?? self)
                case .failure(let error): menu.present(choices: [], error: error.localizedDescription, above: self.stickyBar ?? self)
                }
            }
        }
        return true
    }

    private func acceptCommandCompletion(_ choice: CommandCompletionChoice, request: CommandCompletionRequest) {
        guard completionRequest == request, canInsertCommandForEditing,
              shellEditLine == request.line, shellCursorOffset == request.line.unicodeScalars.count,
              (currentWorkingDirectory() ?? initialWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser) == request.directory else {
            dismissCompletionMenu()
            return
        }
        dismissCompletionMenu()
        stageShellCommand(choice.inserting(into: request))
    }

    private func dismissCompletionMenu() {
        commandCompletions.cancel()
        completionRequest = nil
        completionMenu?.hide()
        completionMenu = nil
    }

    private func sendShellCompletionTab() {
        guard canInsertCommandForEditing, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: PromptEvent.tab) else { return }
        completion.stopTracking()
        sendKey(event, action: GHOSTTY_ACTION_PRESS)
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
        scheduleCompletionRefresh()
    }

    // MARK: - Command block focus and actions

    private func handleCommandBlockKey(_ event: NSEvent) -> Bool {
        let action = CommandBlockInput.action(
            keyCode: event.keyCode, modifiers: event.modifierFlags,
            promptReady: isShellPromptReady, draft: promptLineForSubmission(),
            browsing: isBrowsingCommandBlocks
        )
        switch action {
        case .terminal: return false
        case .previous, .next:
            dismissCommandHistory()
            guard let surface else { return false }
            let result = ghostty_surface_navigate_command_block(
                surface, action == .previous ? -1 : 1, isBrowsingCommandBlocks
            )
            if result == 1 { showCommandBlockSelection() }
            else if isBrowsingCommandBlocks { leaveCommandBlocks() }
            else { return false }
        case .input: leaveCommandBlocks()
        case .reuse: reuseBlockCommand(nil)
        case .actions: blockActions.showActions()
        case .typeInInput:
            leaveCommandBlocks()
            return false
        }
        swallowedKeyCodes.insert(event.keyCode)
        return true
    }

    @discardableResult
    private func selectCommandBlock(at event: NSEvent) -> Bool {
        guard isShellPromptReady, let surface else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard ghostty_surface_select_command_block_at(surface, point.x, bounds.height - point.y) else { return false }
        showCommandBlockSelection()
        return true
    }

    private func showCommandBlockSelection() {
        dismissCommandHistory()
        guard let command = readCommandBlock(command: true) else {
            leaveCommandBlocks()
            return
        }
        isBrowsingCommandBlocks = true
        onFocus?()
        stickyBar?.clearInputSelection()
        ghostText.hide()
        blockActions.update(command: command)
        onBlockSelectionChange?()
        window?.makeFirstResponder(blockActions)
        refreshStickyBar()
    }

    func leaveCommandBlocks(focusInput: Bool = true) {
        guard isBrowsingCommandBlocks else { return }
        isBrowsingCommandBlocks = false
        if let surface { ghostty_surface_clear_command_block(surface) }
        onBlockSelectionChange?()
        refreshStickyBar()
        if focusInput {
            performBinding("scroll_to_bottom")
            window?.makeFirstResponder(self)
            reassertTerminalFocus()
        }
    }

    private func refreshCommandHeader() {
        let pinned = refreshCommandHeader(commandHeaders[0], following: false)
        if pinned {
            _ = refreshCommandHeader(commandHeaders[1], following: true)
        } else {
            commandHeaders[1].isHidden = true
        }
    }

    private func refreshCommandHeader(_ commandHeader: StickyCommandHeaderView, following: Bool) -> Bool {
        guard let surface else { commandHeader.isHidden = true; return false }
        var text = ghostty_text_s()
        var remainingPixels: Double = 0
        var sourcePixels: Double = 0
        var failed = false
        guard ghostty_surface_read_sticky_command(surface, following, &text, &remainingPixels, &sourcePixels, &failed) else {
            commandHeader.isHidden = true
            return false
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { commandHeader.isHidden = true; return false }
        let snapshot = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
        let font = quicklookFont().map { $0 as NSFont } ?? SoraTheme.terminalFont
        if commandHeaderFont != font {
            commandHeaderStyles.removeAll()
            commandHeaderFont = font
        }
        let command: NSAttributedString
        if let cached = commandHeaderStyles[snapshot] {
            command = cached
        } else {
            command = CommandHeaderStyle.attributedCommand(snapshot, font: font)
            if commandHeaderStyles.count >= 8 { commandHeaderStyles.removeAll() }
            commandHeaderStyles[snapshot] = command
        }
        guard command.length > 0 else { commandHeader.isHidden = true; return false }
        let sourceY = sourcePixels / convertToBacking(NSSize(width: 1, height: 1)).height
        // At the start of scrollback there is no departing header to replace.
        // Leave the original command alone until it crosses the pinning point.
        // Later boundaries retain their two-header handoff in both directions.
        guard following || scrollbarOffset > 0 || sourceY < 6 else {
            commandHeader.isHidden = true
            return false
        }
        commandHeader.update(command: command, font: font, failed: failed,
                             remainingHeight: remainingPixels / convertToBacking(NSSize(width: 1, height: 1)).height,
                             sourceY: sourceY,
                             viewport: bounds, cellHeight: cellSize.height)
        return true
    }

    private func readCommandBlock(command: Bool) -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_command_block(surface, command, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return "" }
        let value = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
        return command ? value : CommandBlockText.output(value)
    }

    private func commandBlockMenu() -> NSMenu {
        let menu = NSMenu(title: "Command Block")
        menu.autoenablesItems = false
        let hasCommand = readCommandBlock(command: true) != nil
        let hasOutput = !(readCommandBlock(command: false)?.isEmpty ?? true)
        func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Copy Command", #selector(copyBlockCommand(_:)), enabled: hasCommand)
        add("Copy Output", #selector(copyBlockOutput(_:)), enabled: hasOutput)
        add("Copy Entire Block", #selector(copy(_:)), enabled: hasCommand)
        add("Save Command…", #selector(saveBlockCommand(_:)), enabled: hasCommand)
        add("Save Output…", #selector(saveBlockOutput(_:)), enabled: hasOutput)
        add("Bookmark Block", #selector(bookmarkBlock(_:)), enabled: hasCommand && hasOutput)
        add("Find in Block…", #selector(findInBlock(_:)), enabled: hasCommand)
        add("Ask Agent About Output…", #selector(askAboutOutput(_:)), enabled: hasOutput)
        menu.addItem(.separator())
        add("Use Command in Input", #selector(reuseBlockCommand(_:)),
            enabled: hasCommand && isShellPromptReady && shellEditLine != nil)
        add("Return to Input", #selector(returnFromBlock(_:)))
        return menu
    }

    @objc func askAboutOutput(_ sender: Any?) {
        let source: TerminalOutputAttachment.Source
        let value: String
        var excerpt = false
        if isBrowsingCommandBlocks, let output = readCommandBlock(command: false), !output.isEmpty {
            source = .commandBlock
            value = output
        } else if let surface, ghostty_surface_has_selection(surface) {
            var text = ghostty_text_s()
            guard ghostty_surface_read_selection(surface, &text) else { return }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let bytes = text.text, text.text_len > 0 else { return }
            source = .selection
            let count = min(Int(text.text_len), TerminalOutputAttachment.byteLimit + 4)
            value = String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
            excerpt = Int(text.text_len) > TerminalOutputAttachment.byteLimit
        } else { NSSound.beep(); return }
        onAgentOutput?(TerminalOutputAttachment(source: source,
            command: source == .commandBlock ? readCommandBlock(command: true) : nil,
            directory: currentWorkingDirectory()?.path, text: value, isExcerpt: excerpt))
    }

    @objc private func copyBlockCommand(_ sender: Any?) {
        guard let text = readCommandBlock(command: true) else { NSSound.beep(); return }
        GhosttyClipboard.writePlainText(text, to: .general)
    }

    @objc private func copyBlockOutput(_ sender: Any?) {
        guard let text = readCommandBlock(command: false) else { NSSound.beep(); return }
        GhosttyClipboard.writePlainText(text, to: .general)
    }

    @objc private func saveBlockCommand(_ sender: Any?) {
        guard !isRemoteSession, let command = readCommandBlock(command: true) else { NSSound.beep(); return }
        SavedCommandEditor.present(command: command,
            directory: currentWorkingDirectory() ?? initialWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
            in: window)
    }

    @objc private func bookmarkBlock(_ sender: Any?) {
        guard let command = readCommandBlock(command: true), let output = readCommandBlock(command: false) else { return }
        do {
            let id = try runtime.bookmarks.save(command: command, output: output,
                directory: contextLabel ?? currentWorkingDirectory()?.path ?? initialWorkingDirectory?.path ?? "", tabID: tabID)
            runtime.bookmarkLibrary.show(select: id)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func findInBlock(_ sender: Any?) { showFind(scope: .selectedBlock) }

    @objc private func saveBlockOutput(_ sender: Any?) {
        guard let text = readCommandBlock(command: false), let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "command-output.txt"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc private func reuseBlockCommand(_ sender: Any?) {
        guard isShellPromptReady, shellEditLine != nil,
              let command = readCommandBlock(command: true) else { NSSound.beep(); return }
        leaveCommandBlocks()
        stageShellCommand(command)
    }

    @objc private func returnFromBlock(_ sender: Any?) { leaveCommandBlocks() }

    func acceptStickyPrediction() {
        switch completion.handleKeyDown(
            keyCode: PromptEvent.rightArrow,
            characters: "",
            modifiers: []
        ) {
        case .accept(let suffix):
            insertText(suffix)
            scheduleCompletionRefresh()
        case .passThrough:
            break
        }
    }

    private func quicklookFont() -> CTFont? {
        guard let surface,
              let fontRaw = ghostty_surface_quicklook_font(surface)
        else { return nil }
        // Ghostty returns a +1 CTFont; takeUnretainedValue + release matches
        // Ghostty's own AppKit surface view. Embedded builds may hand back a
        // content-scaled size; pin to the configured terminal size so advance
        // and baseline match the grid.
        let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
        let value = font.takeUnretainedValue()
        font.release()
        let size = CTFontGetSize(value)
        if abs(size - SoraTheme.terminalFontSize) > 0.25 {
            return CTFontCreateCopyWithAttributes(
                value,
                SoraTheme.terminalFontSize,
                nil,
                nil
            )
        }
        return value
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = GhosttyInput.keyEvent(from: event, action: action)
        if let text = GhosttyInput.text(from: event),
           let first = text.utf8.first, first >= 0x20 {
            _ = text.withCString { pointer in
                key.text = pointer
                return ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
        // Flush terminal actions once per input event, independently of the
        // asynchronous suggestion refresh (also needed by fullscreen clients).
        if action != GHOSTTY_ACTION_RELEASE { runtime.tick() }
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = GhosttyInput.surfaceMousePoint(viewPoint: viewPoint, viewHeight: bounds.height)
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            point.y,
            GhosttyInput.mods(from: event.modifierFlags)
        )
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            state,
            button,
            GhosttyInput.mods(from: event.modifierFlags)
        )
    }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(
            surface,
            action,
            UInt(action.lengthOfBytes(using: .utf8))
        )
    }

    func applyShortcuts() {
        stickyBar?.agentShortcut = runtime.shortcuts.binding(.openAgent).display
        refreshStickyBar()
    }

    func applyAppearance() {
        window?.appearance = TerminalPreferences.appearance.native
        dismissCompletionMenu()
        stickyBar?.applyAppearance()
        refreshCommandHeader()
        superview?.needsLayout = true
        needsDisplay = true
    }

    /// Apply a live font size via Ghostty's `set_font_size` binding.
    func applyFontSize(_ points: CGFloat) {
        let clamped = min(
            TerminalPreferences.maximumFontSize,
            max(TerminalPreferences.minimumFontSize, points.rounded())
        )
        performBinding("set_font_size:\(clamped)")
        applyAppearance()
    }
}
