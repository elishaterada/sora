import AppKit

/// Keeps block browsing out of ZLE and fullscreen applications. The shell's
/// input keeps unmodified arrows for history and multiline editing.
enum CommandBlockInput {
    enum Action: Equatable {
        case terminal, previous, next, input, reuse, actions, typeInInput
    }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       promptReady: Bool, draft: String, browsing: Bool) -> Action {
        guard promptReady else { return .terminal }
        let mods = modifiers.intersection([.command, .control, .option, .shift])
        if !browsing {
            if keyCode == PromptEvent.upArrow, mods == [.command] {
                return .previous
            }
            return .terminal
        }
        if mods.isEmpty {
            switch keyCode {
            case PromptEvent.upArrow: return .previous
            case PromptEvent.downArrow: return .next
            case PromptEvent.escape: return .input
            case PromptEvent.returnKey, PromptEvent.keypadEnter: return .reuse
            case PromptEvent.tab: return .actions
            default: break
            }
        }
        if mods == [.command], keyCode == PromptEvent.upArrow { return .previous }
        if mods == [.command], keyCode == PromptEvent.downArrow { return .input }
        return .typeInInput
    }
}

enum CommandBlockText {
    /// A terminal can write spaces to the right edge of its last output row.
    /// Preserve leading indentation and internal blank lines when exporting.
    static func output(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return String(text[..<end])
    }
}
