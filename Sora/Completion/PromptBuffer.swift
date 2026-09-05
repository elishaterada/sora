import AppKit
import Foundation

struct PromptBuffer: Equatable {
    private(set) var text = ""
    private(set) var isTracking = true

    enum Event: Equatable {
        case insert(String)
        case backspace
        case reset
        case stopTracking
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .insert(let value):
            guard isTracking, !value.isEmpty else { return }
            text.append(value)
        case .backspace:
            guard isTracking, !text.isEmpty else { return }
            text.removeLast()
        case .reset:
            text = ""
            isTracking = true
        case .stopTracking:
            text = ""
            isTracking = false
        }
    }
}

enum PromptEvent {
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let tab: UInt16 = 48
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    static func isAcceptKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == tab || keyCode == rightArrow else { return false }
        return modifiers.isDisjoint(with: [.command, .control, .option, .shift])
    }

    /// Mouse focus on an empty ready prompt must keep (or resume) tracking so
    /// conversational Return routing still sees the typed line. A click after
    /// text is present may move the shell caret, so tracking stops.
    static func mouseFocusEvent(isShellPromptReady: Bool, buffer: PromptBuffer) -> PromptBuffer.Event? {
        if isShellPromptReady, buffer.text.isEmpty {
            return .reset
        }
        if !buffer.text.isEmpty {
            return .stopTracking
        }
        return nil
    }

    static func from(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> PromptBuffer.Event? {
        if modifiers.contains(.command) {
            return nil
        }
        if modifiers.contains(.control) {
            // NSEvent.characters contains ASCII control codes for real key
            // events, while some callers supply the printable key name.
            let key = characters.lowercased()
            if key == "c" || key == "\u{03}" || key == "u" || key == "\u{15}" {
                return .reset
            }
            // Cursor movement and partial deletions do not clear the whole
            // shell buffer. Do not classify a subsequently typed suffix alone.
            return .stopTracking
        }
        if modifiers.contains(.option) {
            return .stopTracking
        }

        switch keyCode {
        case returnKey, keypadEnter, escape:
            return .reset
        case delete:
            return .backspace
        case leftArrow, downArrow, upArrow:
            return .stopTracking
        case tab, rightArrow:
            return .stopTracking
        default:
            break
        }

        let filtered = characters.filter { scalar in
            scalar != "\t" && scalar != "\r" && scalar != "\n"
                && scalar.unicodeScalars.allSatisfy { $0.value >= 0x20 }
        }
        if filtered.isEmpty { return nil }
        return .insert(filtered)
    }
}
