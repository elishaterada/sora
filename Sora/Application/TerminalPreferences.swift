import Foundation

/// User preferences that affect terminal and agent chrome.
enum TerminalPreferences {
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
