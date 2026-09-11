import Foundation

/// User preferences that affect terminal and agent chrome.
enum TerminalPreferences {
    static var showsSessionWelcome: Bool {
        get { UserDefaults.standard.object(forKey: "terminal.showsSessionWelcome") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "terminal.showsSessionWelcome") }
    }

    static var automaticAgentRouting: Bool {
        get { UserDefaults.standard.object(forKey: "terminal.automaticAgentRouting") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "terminal.automaticAgentRouting") }
    }
    static let notificationsEnabledKey = "terminal.notificationsEnabled"
    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsEnabledKey) as? Bool ?? true
    }

    static let fontSizeKey = "terminal.fontSize"
    static let defaultFontSize: CGFloat = 18
    static let minimumFontSize: CGFloat = 12
    static let maximumFontSize: CGFloat = 28

    /// Posted on the main queue whenever `fontSize` changes.
    static let fontSizeDidChange = Notification.Name("sora.terminal.fontSizeDidChange")

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: fontSizeKey) as? Double
            let value = CGFloat(stored ?? Double(defaultFontSize))
            return min(maximumFontSize, max(minimumFontSize, value.rounded()))
        }
        set {
            let clamped = min(maximumFontSize, max(minimumFontSize, newValue.rounded()))
            guard clamped != fontSize else { return }
            UserDefaults.standard.set(Double(clamped), forKey: fontSizeKey)
            NotificationCenter.default.post(name: fontSizeDidChange, object: nil, userInfo: ["size": clamped])
        }
    }
}
