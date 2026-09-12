import AppKit
import Carbon
import Combine

/// App-owned Carbon hotkey; no keyboard monitoring or Accessibility permission.
final class GlobalShortcutController: ObservableObject {
    static let enabledKey = "terminal.globalShortcutEnabled"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRegistered = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var enabled: Bool?
    private let defaults: UserDefaults
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private weak var lastWindow: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var observations: [NSObjectProtocol] = []
    var openWindow: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Defaults can change from AppKit font initialization on a background
        // thread. Never synchronously wait for the main queue from that callback.
        observations.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, self.windows.contains(window) else { return }
            self.lastWindow = window
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.windows.remove(window)
            if self.lastWindow === window { self.lastWindow = nil }
        })
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        observations.forEach(NotificationCenter.default.removeObserver)
    }

    func register(window: NSWindow) {
        windows.add(window)
        if window.isKeyWindow || lastWindow == nil { lastWindow = window }
    }

    func refresh() {
        let desired = defaults.bool(forKey: Self.enabledKey)
        guard enabled != desired else { return }
        enabled = desired
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        errorMessage = nil
        isRegistered = false
        guard desired else { return }
        if handler == nil {
            var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID(signature: 0, id: 0)
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == 0x536F7261, id.id == 1 else { return OSStatus(eventNotHandledErr) }
                Unmanaged<GlobalShortcutController>.fromOpaque(context).takeUnretainedValue().toggle()
                return noErr
            }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { errorMessage = "Sora could not install its shortcut handler (\(result))."; return }
        }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: 0x536F7261, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        isRegistered = result == noErr
        if result != noErr {
            errorMessage = "Control–Option–S is unavailable, possibly because another app uses it. Disable that binding or turn this shortcut off (\(result))."
        }
    }

    func toggle() {
        #if DEBUG
        defer {
            DispatchQueue.main.async {
                NSLog("SORA_SHORTCUT active=%@ hidden=%@ front=%@", NSApp.isActive.description, NSApp.isHidden.description,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")
            }
        }
        #endif
        let terminal = lastWindow ?? windows.allObjects.first
        if NSApp.isActive, !NSApp.isHidden, terminal?.isVisible == true {
            NSApp.hide(nil)
            if let previousApplication, !previousApplication.isTerminated { previousApplication.activate(options: []) }
            return
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        guard let terminal else {
            NSApp.activate(ignoringOtherApps: true)
            openWindow?()
            return
        }
        if terminal.isMiniaturized { terminal.deminiaturize(nil) }
        // Keep windows on their existing displays and Spaces. Native activation
        // follows macOS's Space-switching preference instead of moving a window.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        terminal.makeKeyAndOrderFront(nil)
    }
}
