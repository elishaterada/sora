import AppKit
import Combine
import GhosttyKit
import os.log

enum GhosttyRuntimeError: Error, LocalizedError {
    case initializeFailed
    case configFailed
    case appFailed
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .initializeFailed:
            return "ghostty_init failed"
        case .configFailed:
            return "ghostty_config_new failed"
        case .appFailed:
            return "ghostty_app_new failed"
        case .invalidConfig(let message): return message
        }
    }
}

/// Process-wide libghostty app. One instance per Sora process.
final class GhosttyRuntime: ObservableObject {
    private static let logger = Logger(subsystem: "dev.sora.app", category: "GhosttyRuntime")
    private static var didInit = false

    @Published private(set) var windowTitle = "Sora"

    weak var activeSurface: GhosttySurfaceView?
    let notifications = TerminalNotificationController()
    let globalShortcut = GlobalShortcutController()
    let shortcuts = AppShortcutStore()
    let projectLayouts = ProjectLayoutStore()
    let bookmarks = BlockBookmarkStore()
    lazy var bookmarkLibrary = BlockBookmarkLibrary(store: bookmarks)
    let history: CommandHistoryStore

    private(set) var app: ghostty_app_t!
    private var config: ghostty_config_t
    @Published private(set) var configurationError: String?
    private var appearanceObserver: NSObjectProtocol?
    private var systemAppearanceObserver: NSKeyValueObservation?
    private var appliedAppearanceConfig = ""
    let windowStore: WorkspaceWindowStore
    let initialWindowID: UUID
    private var hasOpenedRestoredWindows = false
    private var terminationObserver: NSObjectProtocol?

    init(history: CommandHistoryStore) throws {
        self.history = history
        if !Self.didInit {
            // Pass only argv[0]. Xcode and XCTest append flags Ghostty must not parse.
            let result = ghostty_init(1, CommandLine.unsafeArgv)
            guard result == GHOSTTY_SUCCESS else {
                throw GhosttyRuntimeError.initializeFailed
            }
            Self.didInit = true
        }

        NSApplication.shared.appearance = TerminalPreferences.appearance.native
        self.config = try Self.makeConfig()
        self.appliedAppearanceConfig = Self.appearanceConfig()
        let store = WorkspaceWindowStore()
        self.windowStore = store
        self.initialWindowID = store.windows[0].id
        self.terminationObserver = NotificationCenter.default.addObserver(forName: WorkspaceWindowStore.terminationApproved, object: nil, queue: .main) { [weak store] _ in
            store?.isTerminating = true
        }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                runtime.tick()
                // PTY echo advances the cursor after keyDown; refresh ghost
                // against the updated IME point so suggestions stay on-grid.
                runtime.activeSurface?.scheduleCompletionRefreshFromTerminal()
            }
        }
        runtime.action_cb = { _, target, action in
            GhosttyRuntime.handleAction(target: target, action: action)
        }
        runtime.read_clipboard_cb = { userdata, location, state, _, _, _ in
            GhosttyRuntime.readClipboard(userdata: userdata, location: location, state: state)
        }
        runtime.confirm_read_clipboard_cb = { userdata, _, state, _ in
            // V0: allow OSC 52 / paste reads without a confirmation UI.
            GhosttyRuntime.readClipboard(userdata: userdata, location: GHOSTTY_CLIPBOARD_STANDARD, state: state)
        }
        runtime.write_clipboard_cb = { userdata, location, content, len, confirm in
            _ = confirm
            GhosttyRuntime.writeClipboard(
                userdata: userdata,
                location: location,
                content: content,
                len: len
            )
        }
        runtime.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                view.requestClose()
            }
        }

        guard let app = ghostty_app_new(&runtime, config) else {
            throw GhosttyRuntimeError.appFailed
        }
        self.app = app
        appearanceObserver = NotificationCenter.default.addObserver(forName: TerminalPreferences.appearanceDidChange, object: nil, queue: .main) { [weak self] _ in self?.reloadAppearance() }
        systemAppearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reloadAppearance() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        if let app {
            ghostty_app_free(app)
        }
        ghostty_config_free(config)
    }

    private static func appearanceConfig() -> String {
        var text = TerminalPreferences.ghosttyAppearanceConfig(light: TerminalPreferences.isLight,
            family: TerminalPreferences.fontFamily, compact: TerminalPreferences.compactSpacing, size: TerminalPreferences.fontSize)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { text += "cursor-style-blink = false\n" }
        return text
    }

    private static func makeConfig() throws -> ghostty_config_t {
        guard let config = ghostty_config_new() else { throw GhosttyRuntimeError.configFailed }
        do {
            if let theme = Bundle.main.path(forResource: "sora", ofType: "ghostty") {
                theme.withCString { ghostty_config_load_file(config, $0) }
            }
            // A unique transient file avoids cross-process preference overlays.
            let overlay = FileManager.default.temporaryDirectory.appendingPathComponent("sora-appearance-\(UUID().uuidString).ghostty")
            defer { try? FileManager.default.removeItem(at: overlay) }
            try appearanceConfig().write(to: overlay, atomically: true, encoding: .utf8)
            overlay.path.withCString { ghostty_config_load_file(config, $0) }
            ghostty_config_finalize(config)
            var diagnostics: [String] = []
            for index in 0..<ghostty_config_diagnostics_count(config) {
                if let message = ghostty_config_get_diagnostic(config, index).message { diagnostics.append(String(cString: message)) }
            }
            if !diagnostics.isEmpty { throw GhosttyRuntimeError.invalidConfig(diagnostics.joined(separator: "\n")) }
            return config
        } catch {
            ghostty_config_free(config)
            throw error
        }
    }

    private func reloadAppearance() {
        let desired = Self.appearanceConfig()
        guard desired != appliedAppearanceConfig else { return }
        do {
            let replacement = try Self.makeConfig()
            ghostty_app_update_config(app, replacement)
            ghostty_config_free(config)
            config = replacement
            appliedAppearanceConfig = desired
            configurationError = nil
            NotificationCenter.default.post(name: Self.appearanceApplied, object: self)
        } catch {
            configurationError = "Could not update terminal appearance: " + error.localizedDescription
            Self.logger.error("Appearance update failed: \(error.localizedDescription)")
        }
    }
    static let appearanceApplied = Notification.Name("sora.terminal.appearanceApplied")

    func tick() {
        ghostty_app_tick(app)
    }

    func copyFromActiveSurface() {
        activeSurface?.copySelectionToPasteboard()
    }

    func pasteIntoActiveSurface() {
        activeSurface?.pasteFromPasteboard()
    }

    func selectAllOnActiveSurface() {
        activeSurface?.selectAll(nil)
    }

    func setFocus(_ focused: Bool) {
        ghostty_app_set_focus(app, focused)
    }

    func remainingRestoredWindowIDs(excluding id: UUID) -> [UUID] {
        guard !hasOpenedRestoredWindows else { return [] }
        hasOpenedRestoredWindows = true
        return windowStore.windows.map(\.id).filter { $0 != id }
    }

    func applyTitle(_ title: String) {
        windowTitle = title
    }

    func recordCommand(
        tabID: UUID,
        command: String,
        cwd: URL?,
        exitCode: Int16,
        durationNanos: UInt64
    ) -> CommandRun? {
        guard let run = CommandRunFactory.make(
            command: command,
            cwd: cwd,
            exitCode: exitCode,
            durationNanos: durationNanos
        ) else {
            return nil
        }
        do {
            try history.record(run, tabID: tabID)
        } catch {
            Self.logger.error("failed to persist command history: \(error.localizedDescription, privacy: .public)")
        }
        return run
    }

    func recordTransition(previous: String, next: String, cwd: URL, at: Date) {
        do {
            try history.recordTransition(previous: previous, next: next, cwd: cwd, at: at)
        } catch {
            Self.logger.error("failed to persist command transition: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view = surfaceView(from: target)

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_WINDOW_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            let cTitle: UnsafePointer<CChar>?
            if action.tag == GHOSTTY_ACTION_SET_TAB_TITLE {
                cTitle = action.action.set_tab_title.title
            } else {
                cTitle = action.action.set_title.title
            }
            if let cTitle {
                let title = String(cString: cTitle)
                DispatchQueue.main.async {
                    view?.applyTitle(title)
                }
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // Copy C strings before the callback returns and Ghostty releases them.
            let payload = action.action.desktop_notification
            let title = payload.title.map { String(cString: $0) } ?? ""
            let body = payload.body.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.runtime.notifications.post(title: title, body: body, from: view)
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.runtime.notifications.post(title: "Terminal needs attention", body: view.lastShellTitle, from: view)
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            let query = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view?.showFind(query: query.isEmpty ? nil : query) }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            DispatchQueue.main.async { view?.updateFindCount(total) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let index = action.action.search_selected.selected
            DispatchQueue.main.async { view?.updateFindSelection(index) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            return true // Native panel dismissal owns focus restoration.
        case GHOSTTY_ACTION_PWD:
            if let cPwd = action.action.pwd.pwd {
                let path = String(cString: cPwd)
                DispatchQueue.main.async {
                    view?.applyWorkingDirectory(path)
                }
            }
            return true
        case GHOSTTY_ACTION_NEW_TAB:
            DispatchQueue.main.async {
                view?.requestNewTab()
            }
            return true
        case GHOSTTY_ACTION_CLOSE_TAB:
            let mode = action.action.close_tab_mode
            DispatchQueue.main.async {
                view?.requestCloseTab(mode)
            }
            return true
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = action.action.goto_tab.rawValue
            DispatchQueue.main.async {
                view?.requestGotoTab(raw)
            }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            DispatchQueue.main.async {
                view?.applyCellSize(backingWidth: size.width, backingHeight: size.height)
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            let bar = action.action.scrollbar
            DispatchQueue.main.async {
                view?.applyScrollbar(total: bar.total, offset: bar.offset, len: bar.len)
            }
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = action.action.command_finished
            DispatchQueue.main.async {
                view?.recordCommandFinished(
                    exitCode: finished.exit_code,
                    durationNanos: finished.duration
                )
            }
            return true
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return true
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            DispatchQueue.main.async {
                view?.requestCloseWindow()
            }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            DispatchQueue.main.async {
                view?.applyMouseShape(action.action.mouse_shape)
            }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let request = action.action.open_url
            guard let bytes = request.url, request.len > 0 else { return true }
            let value = String(
                decoding: UnsafeRawBufferPointer(
                    start: UnsafeRawPointer(bytes),
                    count: Int(request.len)
                ),
                as: UTF8.self
            )
            DispatchQueue.main.async {
                openExternalURL(value)
            }
            return true
        default:
            return true
        }
    }

    /// Ghostty owns link recognition and only emits this action after the user
    /// activates a highlighted terminal link. Sora owns the native handoff to
    /// the default browser/application because returning `true` from the
    /// embedded runtime suppresses Ghostty's standalone fallback opener.
    private static func openExternalURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = URL(string: trimmed), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return
        }

        let path = (trimmed as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        let surface = target.target.surface
        guard let userdata = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    @discardableResult
    private static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> ghostty_clipboard_read_result_e {
        guard let view = surfaceView(from: userdata),
              let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        let pasteboard = GhosttyClipboard.pasteboard(for: location)
        guard let text = GhosttyClipboard.plainText(from: pasteboard) else {
            var complete = ghostty_clipboard_complete_s()
            complete.confirmed = true
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        return text.withCString { cString in
            var item = ghostty_clipboard_content_s(
                mime: "text/plain",
                data: cString,
                len: text.utf8.count
            )
            return withUnsafePointer(to: &item) { pointer in
                var complete = ghostty_clipboard_complete_s()
                complete.contents = pointer
                complete.contents_len = 1
                complete.confirmed = true
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
                return GHOSTTY_CLIPBOARD_READ_STARTED
            }
        }
    }

    private static func writeClipboard(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        if let text = GhosttyClipboard.firstPlainText(content: content, count: len),
           surfaceView(from: userdata)?.captureHistoryExport(text) == true { return }
        let pasteboard = GhosttyClipboard.pasteboard(for: location)
        if let text = GhosttyClipboard.firstPlainText(content: content, count: len) {
            GhosttyClipboard.writePlainText(text, to: pasteboard)
        }
    }
}

private extension GhosttySurfaceView {
    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            NSCursor.iBeam.set()
        default:
            NSCursor.arrow.set()
        }
    }
}
