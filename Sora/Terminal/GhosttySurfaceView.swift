import AppKit
import CoreText
import GhosttyKit

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
    let runtime: GhosttyRuntime
    let initialWorkingDirectory: URL?
    weak var delegate: GhosttySurfaceDelegate?
    private(set) var surface: ghostty_surface_t?
    private var hasCreatedSurface = false
    private(set) var lastShellTitle = ""
    private(set) var lastWorkingDirectory: URL?
    private(set) var cellSize = NSSize(width: 8, height: 16)
    private let completion = CompletionSession()
    private let ghostText = GhostTextView()
    private var ghostTextAnchor: GhostTextAnchor?
    private weak var stickyBar: StickyPromptBar?
    private var scrollbarTotal: UInt64 = 0
    private var scrollbarOffset: UInt64 = 0
    private var scrollbarLen: UInt64 = 0
    private var swallowedKeyCodes: Set<UInt16> = []
    private var isShellPromptReady = false
    private var promptIntent: PromptIntent?
    var onAgentPrompt: ((String) -> Void)?
    var onContinueAgent: (() -> Bool)?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init(runtime: GhosttyRuntime, workingDirectory: URL? = nil) {
        self.runtime = runtime
        self.initialWorkingDirectory = workingDirectory
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Do not set wantsLayer or install a CAMetalLayer. libghostty assigns the layer.
        ghostText.isHidden = true
        addSubview(ghostText)
    }

    func attachStickyPromptBar(_ bar: StickyPromptBar) {
        stickyBar = bar
        refreshStickyBar()
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
            window.appearance = NSAppearance(named: .darkAqua)
            createSurfaceIfNeeded()
            updateSurfaceMetrics()
            setOccluded(isHidden)
        } else {
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
        if let anchor = ghostTextAnchor {
            ghostTextAnchor = GhostTextAnchor(
                origin: NSPoint(x: anchor.origin.x, y: anchor.origin.y + newSize.height - frame.height),
                cellWidth: anchor.cellWidth
            )
        }
        super.setFrameSize(newSize)
        updateSurfaceMetrics()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let surface {
            ghostty_surface_set_focus(surface, true)
            runtime.setFocus(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
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
        captureGhostTextAnchor()
        let characters = event.characters ?? ""
        let isReturn = event.keyCode == PromptEvent.returnKey
            || event.keyCode == PromptEvent.keypadEnter
            || characters == "\r" || characters == "\n"
        if isShellPromptReady, isReturn {
            let forceShell = event.modifierFlags.contains(.command)
            switch PromptIntentClassifier.submission(for: completion.buffer.text, forceShell: forceShell) {
            case .agent(let question) where !question.isEmpty:
                swallowedKeyCodes.insert(event.keyCode)
                // Cancel zsh's entire edit buffer before opening AI. A kill-line
                // widget depends on ZLE's transient cursor during redraw and can
                // leave a suffix behind; terminal interrupt cannot submit it.
                cancelPromptLine()
                completion.reset()
                ghostTextAnchor = nil
                isShellPromptReady = true
                refreshCompletion()
                onAgentPrompt?(question)
                return
            case .shell where forceShell:
                swallowedKeyCodes.insert(event.keyCode)
                sendUnmodifiedReturn(keyCode: event.keyCode)
                completion.reset()
                ghostTextAnchor = nil
                isShellPromptReady = false
                refreshCompletion()
                return
            default:
                isShellPromptReady = false
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
            refreshCompletion()
            sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            scheduleCompletionRefresh()
        }
    }

    override func keyUp(with event: NSEvent) {
        if swallowedKeyCodes.remove(event.keyCode) != nil {
            return
        }
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
        let chars = event.charactersIgnoringModifiers ?? ""
        // Let SwiftUI's AI menu handle Ask before terminal key forwarding.
        if chars.lowercased() == "a",
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift] {
            return false
        }
        // File → New Tab (Cmd+N) must reach WorkspaceCommands, not the PTY.
        if chars.lowercased() == "n",
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command] {
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
        performBinding("select_all")
    }

    func copySelectionToPasteboard() {
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

    func pasteFromPasteboard() {
        guard let surface else { return }
        guard let value = GhosttyClipboard.plainText(from: .general), !value.isEmpty else { return }
        captureGhostTextAnchor()
        completion.handlePaste(value)
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) { ghostTextAnchor = nil }
        refreshCompletion()
        insertText(value)
        scheduleCompletionRefresh()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        default:
            return true
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Focusing an empty ready prompt must not kill AI routing. Clicks after
        // the user has typed may move zsh's caret, so those still stop tracking.
        applyPromptMouseFocus()
        ghostTextAnchor = nil
        ghostText.hide()
        refreshCompletion()
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    func applyStickyBarFocus() {
        window?.makeFirstResponder(self)
        applyPromptMouseFocus()
        refreshCompletion()
    }

    private func applyPromptMouseFocus() {
        completion.applyMouseFocus(isShellPromptReady: isShellPromptReady)
    }

    override func mouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func mouseDragged(with event: NSEvent) {
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
            deltaX *= 2
            deltaY *= 2
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
        refreshCompletion()
    }

    // MARK: - Lifecycle

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
        config.font_size = 0
        config.command = nil
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB

        let zdotdir = SoraZshBootstrap.defaultDirectory().path
        let created: ghostty_surface_t? = "ZDOTDIR".withCString { keyPtr in
            zdotdir.withCString { valuePtr in
                var env = ghostty_env_var_s(key: keyPtr, value: valuePtr)
                return withUnsafeMutablePointer(to: &env) { envPtr in
                    config.env_vars = envPtr
                    config.env_var_count = 1
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

        guard let created else {
            assertionFailure("ghostty_surface_new failed")
            return
        }
        surface = created
        // A user cannot type until the created surface has presented its first
        // prompt. Later submissions set this false until OSC 133 D reports the
        // foreground command finished, so REPL/program input is never routed.
        isShellPromptReady = true
        runtime.activeSurface = self
        runtime.tick()
        updateSurfaceMetrics()
        ghostty_surface_set_focus(created, true)
        ghostty_surface_set_occlusion(created, true)
    }

    func setActive(_ active: Bool) {
        isHidden = !active
        setOccluded(!active)
        if active {
            runtime.activeSurface = self
            updateSurfaceMetrics()
            window?.makeFirstResponder(self)
        } else {
            ghostText.hide()
            if runtime.activeSurface === self {
                runtime.activeSurface = nil
            }
        }
    }

    func closeSession() {
        destroySurface()
    }

    func currentWorkingDirectory() -> URL? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0, pid <= UInt64(pid_t.max) else { return nil }
        return ForegroundWorkingDirectory.url(pid: pid_t(pid))
    }

    func applyTitle(_ title: String) {
        lastShellTitle = title
        let value = title.isEmpty ? "Sora" : title
        if runtime.activeSurface === self {
            window?.title = value
        }
        runtime.applyTitle(value)
        delegate?.surface(self, didChangeTitle: value)
    }

    func applyWorkingDirectory(_ path: String) {
        let url = URL(fileURLWithPath: path)
        lastWorkingDirectory = url
        refreshStickyBar()
        delegate?.surface(self, didChangeWorkingDirectory: url)
    }

    func recordCommandFinished(exitCode: Int16, durationNanos: UInt64) {
        isShellPromptReady = true
        let cwd = lastWorkingDirectory ?? currentWorkingDirectory() ?? initialWorkingDirectory
        let run = runtime.recordCommand(
            command: lastShellTitle,
            cwd: cwd,
            exitCode: exitCode,
            durationNanos: durationNanos
        )
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
        isShellPromptReady && completion.buffer.isTracking && completion.buffer.text.isEmpty
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

    private func insertText(_ value: String) {
        guard let surface, !value.isEmpty else { return }
        value.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(value.utf8.count))
        }
    }

    /// Send an actual Control-C key event. `ghostty_surface_text` is for text
    /// input and intentionally does not encode C0 control bytes for zsh.
    private func cancelPromptLine() {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.keycode = 8 // macOS hardware keycode for C
        key.mods = GHOSTTY_MODS_CTRL
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = UnicodeScalar("c").value
        key.composing = false
        key.text = nil
        key.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, key)
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
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
        runtime.tick()
        DispatchQueue.main.async { [weak self] in
            self?.refreshCompletion()
        }
    }

    /// Called from libghostty's wakeup after PTY output moves the cursor.
    func scheduleCompletionRefreshFromTerminal() {
        guard completion.suggestion != nil || !completion.buffer.text.isEmpty else { return }
        scheduleCompletionRefresh()
    }

    private func refreshCompletion() {
        runtime.tick()
        let cwd = lastWorkingDirectory
            ?? currentWorkingDirectory()
            ?? initialWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        completion.refresh(cwd: cwd, history: runtime.history)
        let route = isShellPromptReady && completion.buffer.isTracking && !completion.buffer.text.isEmpty
            ? PromptIntentClassifier.intent(for: completion.buffer.text)
            : nil
        promptIntent = route
        refreshStickyBar()

        let atLivePrompt = StickyPromptBarModel.isViewingLivePrompt(
            total: scrollbarTotal,
            offset: scrollbarOffset,
            len: scrollbarLen
        )
        guard let suggestion = completion.suggestion, let surface, atLivePrompt, window != nil, !isHidden else {
            ghostText.hide()
            return
        }
        // Next-command prediction lives in the sticky footer so scrollback
        // never paints through it.
        if suggestion.source == .prediction {
            ghostText.hide()
            return
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        _ = width
        let font = quicklookFont() ?? SoraTheme.terminalCTFont
        let cellHeight: CGFloat = height > 0
            ? CGFloat(height)
            : (cellSize.height > 0 ? cellSize.height : 16)
        // Prefer Ghostty's CELL_SIZE width for both IME half-cell and pitch so
        // suggested glyphs land on the same columns as typed characters.
        let cellWidth = cellSize.width > 0
            ? cellSize.width
            : GhosttyInput.ghostTextCellWidth(
                imeHeight: cellHeight,
                cellSize: cellSize,
                font: font
            )
        guard let origin = ghostTextAnchor?.position(
            for: completion.buffer, viewWidth: bounds.width
        ) else {
            ghostText.hide()
            return
        }
        ghostText.show(
            text: suggestion.displayText,
            origin: origin,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            font: font,
            predicted: false
        )
    }

    private func captureGhostTextAnchor() {
        guard completion.buffer.isTracking, completion.buffer.text.isEmpty,
              ghostTextAnchor == nil, let surface else { return }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        ghostTextAnchor = GhostTextAnchor(
            origin: GhosttyInput.ghostTextOrigin(
                imeX: x, imeY: y, viewHeight: bounds.height, cellWidth: cellSize.width
            ),
            cellWidth: cellSize.width
        )
    }

    private func refreshStickyBar() {
        guard let stickyBar else { return }
        let cwd = lastWorkingDirectory
            ?? currentWorkingDirectory()
            ?? initialWorkingDirectory
        let path = StickyPromptBarModel.displayPath(for: cwd)
        let branch = cwd.flatMap { GitRepository.branchName(containing: $0) }
        let atLivePrompt = StickyPromptBarModel.isViewingLivePrompt(
            total: scrollbarTotal,
            offset: scrollbarOffset,
            len: scrollbarLen
        )
        let suggestion = completion.suggestion
        let line: String?
        let predicted: Bool
        if let suggestion, suggestion.source == .prediction {
            line = suggestion.displayText
            predicted = true
        } else if !atLivePrompt {
            let buffer = completion.buffer.text
            if buffer.isEmpty, suggestion == nil {
                line = nil
                predicted = false
            } else {
                let suffix = suggestion?.displayText ?? ""
                line = buffer + suffix
                predicted = suggestion?.source == .prediction
            }
        } else {
            line = nil
            predicted = false
        }
        stickyBar.update(
            path: path,
            directory: cwd,
            branch: branch,
            line: line,
            predicted: predicted
        )
        stickyBar.updateRoute(promptIntent)
    }

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
}
