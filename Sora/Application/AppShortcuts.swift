import AppKit
import SwiftUI

struct AppKeyBinding: Codable, Equatable {
    let key: String
    let modifiers: UInt
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift]).rawValue
    }
    init(event: NSEvent) {
        // Control-modified arrow events may not produce characters through the
        // keyboard layout translator. Their physical navigation identity is stable.
        let arrow = [123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}"][Int(event.keyCode)]
        self.init(arrow ?? event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "", event.modifierFlags)
    }
    var nativeModifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isValid: Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789[];,./'-=\\`\u{F700}\u{F701}\u{F702}\u{F703}").contains($0)
        } && nativeModifiers.contains(.command)
            && modifiers == nativeModifiers.intersection([.command, .control, .option, .shift]).rawValue
    }
    var equivalent: KeyEquivalent { KeyEquivalent(key.first ?? " ") }
    var swiftModifiers: EventModifiers {
        var result: EventModifiers = []
        if nativeModifiers.contains(.command) { result.insert(.command) }
        if nativeModifiers.contains(.control) { result.insert(.control) }
        if nativeModifiers.contains(.option) { result.insert(.option) }
        if nativeModifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
    var display: String {
        let symbol = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→"][key] ?? key.uppercased()
        return (nativeModifiers.contains(.control) ? "⌃" : "") + (nativeModifiers.contains(.option) ? "⌥" : "")
            + (nativeModifiers.contains(.shift) ? "⇧" : "") + (nativeModifiers.contains(.command) ? "⌘" : "") + symbol
    }
}

enum AppShortcutAction: String, CaseIterable, Identifiable, Codable {
    case newWindow, newTab, closeTab, findOutput, commandPalette, splitRight, singlePane
    case splitBelow, maximizePane, focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown
    case renameTab, moveTabUp, moveTabDown, reopenTab, nextTab, previousTab, openAgent, toggleSidebar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .findOutput: return "Find in Terminal Output"
        case .commandPalette: return "Command Palette"
        case .splitRight: return "Split Terminal Side by Side"
        case .singlePane: return "Return to Single Pane"
        case .splitBelow: return "Split Terminal Below"
        case .maximizePane: return "Maximize Pane"
        case .focusPaneLeft: return "Focus Pane Left"
        case .focusPaneRight: return "Focus Pane Right"
        case .focusPaneUp: return "Focus Pane Above"
        case .focusPaneDown: return "Focus Pane Below"
        case .renameTab: return "Rename Tab"
        case .moveTabUp: return "Move Tab Up"
        case .moveTabDown: return "Move Tab Down"
        case .reopenTab: return "Reopen Closed Tab"
        case .nextTab: return "Show Next Tab"
        case .previousTab: return "Show Previous Tab"
        case .openAgent: return "Open Agent"
        case .toggleSidebar: return "Toggle Sidebar"
        }
    }
    var defaultBinding: AppKeyBinding {
        switch self {
        case .newWindow: return AppKeyBinding("n")
        case .newTab: return AppKeyBinding("t")
        case .closeTab: return AppKeyBinding("w")
        case .findOutput: return AppKeyBinding("f")
        case .commandPalette: return AppKeyBinding("p", [.command, .shift])
        case .splitRight: return AppKeyBinding("d")
        case .splitBelow: return AppKeyBinding("d", [.command, .option])
        case .maximizePane: return AppKeyBinding("m", [.command, .control])
        case .focusPaneLeft: return AppKeyBinding("\u{F702}", [.command, .control])
        case .focusPaneRight: return AppKeyBinding("\u{F703}", [.command, .control])
        case .focusPaneUp: return AppKeyBinding("\u{F700}", [.command, .control])
        case .focusPaneDown: return AppKeyBinding("\u{F701}", [.command, .control])
        case .singlePane: return AppKeyBinding("d", [.command, .shift])
        case .renameTab: return AppKeyBinding("r", [.command, .shift])
        case .moveTabUp: return AppKeyBinding("\u{F700}", [.command, .option])
        case .moveTabDown: return AppKeyBinding("\u{F701}", [.command, .option])
        case .reopenTab: return AppKeyBinding("t", [.command, .shift])
        case .nextTab: return AppKeyBinding("]", [.command, .shift])
        case .previousTab: return AppKeyBinding("[", [.command, .shift])
        case .openAgent: return AppKeyBinding("a", [.command, .shift])
        case .toggleSidebar: return AppKeyBinding("s", [.command, .control])
        }
    }
}

final class AppShortcutStore: ObservableObject {
    static let defaultsKey = "terminal.appShortcuts.v1"
    static let didChange = Notification.Name("sora.appShortcutsDidChange")
    @Published private(set) var overrides: [String: AppKeyBinding] = [:]
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            let saved = try JSONDecoder().decode([String: AppKeyBinding].self, from: data)
            var candidate: [String: AppKeyBinding] = [:]
            for action in AppShortcutAction.allCases {
                if let value = saved[action.rawValue] { candidate[action.rawValue] = value }
            }
            for action in AppShortcutAction.allCases {
                if let message = Self.conflict(binding: candidate[action.rawValue] ?? action.defaultBinding, for: action, overrides: candidate) {
                    errorMessage = "Saved shortcuts could not be loaded: " + message + " Restore defaults or record a new shortcut."
                    return
                }
            }
            overrides = candidate
        } catch { errorMessage = "Saved shortcuts could not be read. Restore defaults or record a new shortcut." }
    }
    func binding(_ action: AppShortcutAction) -> AppKeyBinding { overrides[action.rawValue] ?? action.defaultBinding }
    func matches(_ event: NSEvent) -> Bool {
        let pressed = AppKeyBinding(event: event)
        return AppShortcutAction.allCases.contains { binding($0) == pressed }
    }
    @discardableResult
    func set(_ binding: AppKeyBinding, for action: AppShortcutAction) -> Bool {
        if let message = Self.conflict(binding: binding, for: action, overrides: overrides) { errorMessage = message; return false }
        if let menu = NSApp?.mainMenu, let title = Self.otherMenuConflict(binding, menu: menu) {
            errorMessage = "\(binding.display) is already used by \(title). Choose another shortcut."
            return false
        }
        var updated = overrides
        updated[action.rawValue] = binding == action.defaultBinding ? nil : binding
        return persist(updated)
    }
    func reset(_ action: AppShortcutAction) { _ = set(action.defaultBinding, for: action) }
    func resetAll() { _ = persist([:]) }
    private func persist(_ updated: [String: AppKeyBinding]) -> Bool {
        do {
            defaults.set(try JSONEncoder().encode(updated), forKey: Self.defaultsKey)
            overrides = updated
            errorMessage = nil
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private static func otherMenuConflict(_ binding: AppKeyBinding, menu: NSMenu) -> String? {
        let managed = Set(AppShortcutAction.allCases.map(\.title) + ["Show Sidebar", "Hide Sidebar", "Restore Pane Layout"])
        for item in menu.items {
            if let submenu = item.submenu, let title = otherMenuConflict(binding, menu: submenu) { return title }
            let title = item.title.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            guard !managed.contains(title), !item.keyEquivalent.isEmpty else { continue }
            if AppKeyBinding(item.keyEquivalent, item.keyEquivalentModifierMask) == binding { return title }
        }
        return nil
    }
    static func conflict(binding: AppKeyBinding, for action: AppShortcutAction, overrides: [String: AppKeyBinding]) -> String? {
        guard binding.isValid else { return "Use Command with a letter, number, punctuation key or arrow. Option, Shift and Control are optional." }
        // Keep standard editing, quit, visibility, tab numbers and terminal-owned
        // interactions available. The global shortcut is configured separately.
        let reserved = ["q", "h", "m", ",", "c", "v", "x", "a", "z", "y", "=", "-", "0"] + (1...9).map(String.init)
        if binding.nativeModifiers == .command && reserved.contains(binding.key)
            || binding == AppKeyBinding("z", [.command, .shift])
            || binding == AppKeyBinding("h", [.command, .option]) {
            return "\(binding.display) is reserved for a standard app or terminal action."
        }
        for other in AppShortcutAction.allCases where other != action {
            if (overrides[other.rawValue] ?? other.defaultBinding) == binding {
                return "\(binding.display) is already used by \(other.title). Change that shortcut first."
            }
        }
        return nil
    }
}

extension View {
    func appShortcut(_ action: AppShortcutAction, store: AppShortcutStore) -> some View {
        let binding = store.binding(action)
        return keyboardShortcut(binding.equivalent, modifiers: binding.swiftModifiers)
    }
}
