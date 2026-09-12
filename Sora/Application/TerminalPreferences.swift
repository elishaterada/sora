import AppKit
import SwiftUI

/// User preferences that affect terminal and agent chrome.
enum TerminalPreferences {
    enum Appearance: String, CaseIterable, Identifiable {
        case dark, light, system
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var native: NSAppearance? {
            switch self {
            case .dark: return NSAppearance(named: .darkAqua)
            case .light: return NSAppearance(named: .aqua)
            case .system: return nil
            }
        }
        var colorScheme: ColorScheme? {
            switch self { case .dark: return .dark; case .light: return .light; case .system: return nil }
        }
    }
    static let appearanceKey = "terminal.appearance"
    static let fontFamilyKey = "terminal.fontFamily"
    static let compactSpacingKey = "terminal.compactSpacing"
    static let appearanceDidChange = Notification.Name("sora.terminal.appearanceDidChange")
    static var appearance: Appearance { Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .dark }
    static var isLight: Bool {
        appearance == .light || (appearance == .system && NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }
    static var compactSpacing: Bool { UserDefaults.standard.bool(forKey: compactSpacingKey) }
    static let fontFamilies: [String] = {
        let names = NSFontManager.shared.availableFontFamilies.filter { family in
            guard family.count <= 100, !family.contains(where: { "\"\\\n\r".contains($0) }),
                  let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 14) else { return false }
            return font.isFixedPitch
        }
        return Array(Set(names + ["SF Mono"])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()
    static var fontFamily: String { validatedFontFamily(UserDefaults.standard.string(forKey: fontFamilyKey)) }
    static func validatedFontFamily(_ value: String?) -> String {
        guard let value, fontFamilies.contains(value) else { return "SF Mono" }
        return value
    }
    static func appearanceChanged() {
        NSApplication.shared.appearance = appearance.native
        NotificationCenter.default.post(name: appearanceDidChange, object: nil)
    }
    static func resetAppearance() {
        for key in [appearanceKey, fontFamilyKey, compactSpacingKey] { UserDefaults.standard.removeObject(forKey: key) }
        fontSize = defaultFontSize
        appearanceChanged()
    }

    static func ghosttyAppearanceConfig(light: Bool, family: String, compact: Bool, size: CGFloat) -> String {
        var lines = ["font-family =", "font-family = \"\(validatedFontFamily(family))\"", "font-size = \(size)",
                     "window-padding-x = \(compact ? 16 : 24)", "window-padding-y = \(compact ? 10 : 18)",
                     "adjust-cell-height = \(compact ? 4 : 12)%"]
        if light {
            lines += ["background = #f7f8fa", "foreground = #242833", "background-opacity = 1",
                      "cursor-color = #00796b", "cursor-text = #ffffff",
                      "selection-background = #c7e3e1", "selection-foreground = #182d30"]
            let palette = ["242833", "b42349", "00796b", "8a4b00", "175fb3", "a22d78", "6744ad", "444b59",
                           "626b7a", "bd1a45", "006c60", "805100", "135fae", "972568", "6240a4", "18212c"]
            lines += palette.enumerated().map { "palette = \($0.offset)=#\($0.element)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
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

    static let completionAlertsEnabledKey = "terminal.completionAlertsEnabled"
    static let completionAlertThresholdKey = "terminal.completionAlertThreshold"
    static var completionAlertsEnabled: Bool {
        UserDefaults.standard.object(forKey: completionAlertsEnabledKey) as? Bool ?? true
    }
    static var completionAlertThreshold: TimeInterval {
        TerminalNotificationPolicy.completionThreshold(UserDefaults.standard.object(forKey: completionAlertThresholdKey) as? Double ?? 30)
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
