import AppKit
import UserNotifications
import os.log

/// Owns native delivery; terminal escape sequences are parsed by libghostty.
final class TerminalNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "dev.sora.app", category: "TerminalNotifications")
    private var sources: [String: WeakSurface] = [:]
    private var lastDelivery: [String: Date] = [:]

    private struct WeakSurface {
        weak var view: GhosttySurfaceView?
    }

    override init() {
        super.init()
        center.delegate = self
    }

    func post(title: String, body: String, from view: GhosttySurfaceView) {
        view.onBell?()
        // A visible, focused terminal already has the user's attention.
        sources = sources.filter { $0.value.view != nil }
        lastDelivery = lastDelivery.filter { sources[$0.key] != nil }
        let id = view.notificationID.uuidString
        let now = Date()
        guard TerminalNotificationPolicy.shouldDeliver(
            enabled: TerminalPreferences.notificationsEnabled,
            appActive: NSApp.isActive, keyWindow: view.window?.isKeyWindow == true,
            firstResponder: view.window?.firstResponder === view,
            lastDelivery: lastDelivery[id], now: now
        ) else { return }
        lastDelivery[id] = now
        sources[id] = WeakSurface(view: view)
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Terminal needs attention" : String(title.prefix(256))
        content.body = String(body.prefix(4096))
        content.sound = .default
        content.threadIdentifier = id
        // Ask lazily, only when a terminal first requests a background alert.
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { self?.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
            guard TerminalPreferences.notificationsEnabled else { return }
            guard granted else {
                self?.logger.info("Terminal notification permission is disabled")
                return
            }
            self?.center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                if let error { self?.logger.error("Notification delivery failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(TerminalPreferences.notificationsEnabled ? [.banner, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let view = self?.sources[id]?.view else { return }
            view.onNotificationActivate?()
            NSApp.activate(ignoringOtherApps: true)
            view.window?.makeKeyAndOrderFront(nil)
            view.window?.makeFirstResponder(view)
        }
    }
}
