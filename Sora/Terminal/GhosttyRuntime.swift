import AppKit
import Combine
import GhosttyKit
import os.log

enum GhosttyRuntimeError: Error, LocalizedError {
    case initializeFailed
    case configFailed
    case appFailed

    var errorDescription: String? {
        switch self {
        case .initializeFailed:
            return "ghostty_init failed"
        case .configFailed:
            return "ghostty_config_new failed"
        case .appFailed:
            return "ghostty_app_new failed"
        }
    }
}

/// Process-wide libghostty app. One instance per Sora process.
final class GhosttyRuntime: ObservableObject {
    private static let logger = Logger(subsystem: "dev.sora.app", category: "GhosttyRuntime")
    private static var didInit = false

    @Published private(set) var windowTitle = "Sora"

    weak var activeSurface: GhosttySurfaceView?
    let history: CommandHistoryStore

    private(set) var app: ghostty_app_t!
    private let config: ghostty_config_t
    private var launchSnapshot: WorkspaceSnapshot

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

        guard let config = ghostty_config_new() else {
            throw GhosttyRuntimeError.configFailed
        }
        // Blank config plus bundled Sora theme. Do not load ~/.config/ghostty.
        if let theme = Bundle.main.path(forResource: "sora", ofType: "ghostty") {
            theme.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }
        ghostty_config_finalize(config)
        let problems = ghostty_config_diagnostics_count(config)
        if problems > 0 {
            Self.logger.error("sora.ghostty has \(problems) diagnostic(s)")
        }
        self.config = config
        self.launchSnapshot = WorkspaceRestore.load()

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
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        ghostty_config_free(config)
    }

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

    func peekRestoreSnapshot() -> WorkspaceSnapshot {
        launchSnapshot
    }

    func markRestoreConsumed() {
        launchSnapshot = .empty
    }

    func applyTitle(_ title: String) {
        windowTitle = title
    }

    func recordCommand(
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
            try history.record(run)
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
        default:
            return true
        }
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
        _ = userdata
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
