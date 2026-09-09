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
    private let ghostText = GhostTextView()
    private var ghostTextAnchor: GhostTextAnchor?
    private weak var stickyBar: StickyPromptBar?
    private var scrollbarTotal: UInt64 = 0
    private var scrollbarOffset: UInt64 = 0
    private var scrollbarLen: UInt64 = 0
    private var swallowedKeyCodes: Set<UInt16> = []
    private var isShellPromptReady = false
    /// Live ZLE buffer mirrored by the shell. Nil until the first report.
    private var promptContextDirectory: URL?
    private var promptContextBranch: String?
    private var completionRefreshPending = false
    private var shellRecognizesCommand = false
    private var shellEditLine: String?
    private var shellCursorOffset = 0
    private var promptIntent: PromptIntent?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int16) -> Void)?
    let notificationID = UUID()
    var onNotificationActivate: (() -> Void)?
    var onBell: (() -> Void)?
    var draftText: String { isShellPromptReady ? promptLineForSubmission() : "" }
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
        // Layer-back the overlay so it composites in the same space as the
        // libghostty Metal layer instead of drifting in the non-layer path.
        ghostText.wantsLayer = true
        ghostText.layer?.backgroundColor = NSColor.clear.cgColor
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
        super.setFrameSize(newSize)
        updateSurfaceMetrics()
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
        stickyBar?.resetCaretBlink()
        stickyBar?.clearInputSelection()
        captureGhostTextAnchor()
        let characters = event.characters ?? ""
        let isReturn = event.keyCode == PromptEvent.returnKey
            || event.keyCode == PromptEvent.keypadEnter
            || characters == "\r" || characters == "\n"
        // Fullscreen applications own their input; do not query history or the
        // filesystem, rank shell suggestions, or intercept Tab/Right Arrow.
        if !isShellPromptReady && !(isReturn && foregroundProcessIsShell()) {
            sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            return
        }
        if isReturn && event.modifierFlags.contains(.shift) && isShellPromptReady {
            swallowedKeyCodes.insert(event.keyCode)
            insertText("\n")
            return
        }
        if isReturn {
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
            if stickyBar?.selectedInputText != nil { return true }
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        default:
            return true
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
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
        window?.makeFirstResponder(self)
        reassertTerminalFocus()
        applyPromptMouseFocus()
        refreshCompletion()
    }

    func insertDictatedText(_ value: String) {
        guard !value.isEmpty else { return }
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

    private var findPanel: TerminalFindPanel?
    func showFind() {
        if findPanel == nil { findPanel = TerminalFindPanel(surface: self) }
        findPanel?.show()
    }
    func updateFindCount(_ count: Int) { findPanel?.setCount(count) }
    func searchOutput(_ query: String) { performBinding("search:" + query) }
    func navigateFind(previous: Bool) { performBinding("navigate_search:" + (previous ? "previous" : "next")) }
    func endFind() { performBinding("end_search") }
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

    func setActive(_ active: Bool, visible: Bool? = nil) {
        isHidden = !(visible ?? active)
        setOccluded(!(visible ?? active))
        if active {
            runtime.activeSurface = self
            updateSurfaceMetrics()
            window?.makeFirstResponder(self)
            // makeFirstResponder is a no-op when we are already first responder,
            // so always re-assert Ghostty focus after un-occlusion. Leaving the
            // agent overlay clears focus via occlusion; without this the blink
            // shader sees iFocus=0 and custom-shader-animation never runs.
            reassertTerminalFocus()
        } else {
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

    func currentWorkingDirectory() -> URL? {
        guard let surface else { return nil }
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

    func applyTitle(_ title: String) {
        if title == ShellEditLine.commandStartedTitle {
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
            shellCursorOffset = ShellEditLine.cursorOffset(title: title) ?? line.unicodeScalars.count
            // Only ZLE emits this, so the shell is definitionally at a prompt.
            isShellPromptReady = true
            // Arrives on every redraw; avoid the history/path work in a full refresh.
            refreshPromptRoute()
            refreshStickyBar()
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
        delegate?.surface(self, didChangeWorkingDirectory: url)
    }

    func recordCommandFinished(exitCode: Int16, durationNanos: UInt64) {
        onCommandFinished?(exitCode)
        isShellPromptReady = true
        shellEditLine = ""
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
        guard isShellPromptReady,
              completion.suggestion != nil || !completion.buffer.text.isEmpty else { return }
        scheduleCompletionRefresh()
    }

    /// Recomputes only the shell/agent route label for the current line.
    private func displayIntent(for line: String) -> PromptIntent {
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
        guard isShellPromptReady else {
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
        let cwd = lastWorkingDirectory
            ?? currentWorkingDirectory()
            ?? initialWorkingDirectory
        let path = StickyPromptBarModel.displayPath(for: cwd)
        if promptContextDirectory != cwd {
            promptContextDirectory = cwd
            promptContextBranch = cwd.flatMap { GitRepository.branchName(containing: $0) }
        }
        let branch = promptContextBranch
        let suggestion = completion.suggestion
        let buffer = shellEditLine ?? completion.buffer.text
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
        stickyBar.updateCaret(text: buffer, scalarOffset: shellCursorOffset,
                              visible: isShellPromptReady)
        stickyBar.updatePromptReady(isShellPromptReady)
        stickyBar.updateRoute(promptIntent)
        let validSuffix = completion.buffer.isTracking && completion.buffer.text == buffer
            && shellCursorOffset == buffer.unicodeScalars.count && !buffer.isEmpty
            && suggestion?.source != .prediction && promptIntent != .agent
        stickyBar.updateSuggestion(validSuffix ? suggestion?.insertSuffix : nil)
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

    /// Apply a live font size via Ghostty's `set_font_size` binding.
    func applyFontSize(_ points: CGFloat) {
        let clamped = min(
            TerminalPreferences.maximumFontSize,
            max(TerminalPreferences.minimumFontSize, points.rounded())
        )
        performBinding("set_font_size:\(clamped)")
    }
}


/// Native floating find bar; Ghostty owns matching, highlighting and scrolling.
private final class TerminalFindPanel: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    private weak var surface: GhosttySurfaceView?
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 76),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    private let field = NSSearchField(frame: NSRect(x: 12, y: 38, width: 330, height: 24))
    private let count = NSTextField(labelWithString: "Type to search output")
    init(surface: GhosttySurfaceView) {
        self.surface = surface
        super.init()
        panel.title = "Find in Terminal Output"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        field.placeholderString = "Find in output"
        field.delegate = self
        panel.contentView?.addSubview(field)
        count.frame = NSRect(x: 12, y: 10, width: 320, height: 20)
        panel.contentView?.addSubview(count)
        let previous = NSButton(title: "↑", target: self, action: #selector(previousMatch))
        previous.setAccessibilityLabel("Previous match")
        previous.frame = NSRect(x: 350, y: 35, width: 48, height: 28)
        let next = NSButton(title: "↓", target: self, action: #selector(nextMatch))
        next.setAccessibilityLabel("Next match")
        next.frame = NSRect(x: 404, y: 35, width: 48, height: 28)
        panel.contentView?.addSubview(previous)
        panel.contentView?.addSubview(next)
    }
    func show() {
        if let window = surface?.window {
            panel.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX - 490, y: window.frame.maxY - 80))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }
    func setCount(_ total: Int) { count.stringValue = total < 0 ? "Searching…" : "\(total) matches" }
    func controlTextDidChange(_ obj: Notification) { surface?.searchOutput(field.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            surface?.navigateFind(previous: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { panel.close(); return true }
        return false
    }
    @objc private func previousMatch() { surface?.navigateFind(previous: true) }
    @objc private func nextMatch() { surface?.navigateFind(previous: false) }
    func windowWillClose(_ notification: Notification) {
        surface?.endFind()
        surface?.window?.makeKeyAndOrderFront(nil)
        if let surface { surface.window?.makeFirstResponder(surface) }
    }
}
