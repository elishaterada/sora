import Foundation

/// zsh mirrors its live ZLE buffer to Sora through a sentinel-prefixed OSC 2
/// title. That buffer is the only authoritative prompt line: keystroke tracking
/// desyncs on paste, history recall, and completion, and the rendered grid has
/// no prompt boundary to scrape because `PS1` is empty.
enum ShellEditLine {
    static let commandStartedTitle = "\u{2400}sora-command-started\u{2400}"
    static let multilineSentinel = "\u{2400}sora-multiline\u{2400}"
    static let inputSentinel = "\u{2400}sora-input\u{2400}"

    static func shellRecognizesCommand(title: String) -> Bool {
        let title = title.replacingOccurrences(of: multilineSentinel, with: inputSentinel, options: .anchored)
        guard title.hasPrefix(inputSentinel) else { return false }
        return title.dropFirst(inputSentinel.count).split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).dropFirst().first == "1"
    }

    private static func legacyTitle(_ title: String) -> String {
        let encoded = title.hasPrefix(multilineSentinel)
        let title = title.replacingOccurrences(of: multilineSentinel, with: inputSentinel, options: .anchored)
        guard title.hasPrefix(inputSentinel) else { return title }
        let parts = title.dropFirst(inputSentinel.count).split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "0" || parts[1] == "1" else { return title }
        let text = String(parts[2])
        let decoded = encoded ? text.replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%0D", with: "\r")
            .replacingOccurrences(of: "%1B", with: "\u{1B}")
            .replacingOccurrences(of: "%07", with: "\u{07}")
            .replacingOccurrences(of: "%25", with: "%") : text
        return cursorSentinel + parts[0] + ";" + decoded
    }

    static let cursorSentinel = "\u{2400}sora-cursor\u{2400}"

    static func cursorOffset(title: String) -> Int? {
        let title = legacyTitle(title)
        guard title.hasPrefix(cursorSentinel),
              let separator = title.dropFirst(cursorSentinel.count).firstIndex(of: ";"),
              let value = Int(title[title.index(title.startIndex, offsetBy: cursorSentinel.count)..<separator]),
              value >= 0 else { return nil }
        return value
    }

    static func textBeforeCursor(_ text: String, scalarOffset: Int) -> String {
        String(text.unicodeScalars.prefix(max(0, scalarOffset)))
    }

    static let sentinel = "\u{2400}sora-line\u{2400}"

    /// ASCII RS (0x1E). `command-blocks.zsh` binds this to the handoff widget.
    /// Delivered as Ctrl+6 through `ghostty_surface_key` — Ghostty's ctrlSeq
    /// maps that to RS. A bare codepoint writes nothing, and
    /// `ghostty_surface_text` is paste so it never runs bindkey.
    static let agentHandoffControl = UnicodeScalar(0x1E)!

    /// Returns the mirrored edit buffer, or nil when the title is a normal one.
    static func parse(title: String) -> String? {
        let title = legacyTitle(title)
        if cursorOffset(title: title) != nil,
           let separator = title.dropFirst(cursorSentinel.count).firstIndex(of: ";") {
            return String(title[title.index(after: separator)...])
        }
        guard title.hasPrefix(sentinel) else { return nil }
        return String(title.dropFirst(sentinel.count))
    }

    static func isMirror(title: String) -> Bool {
        title.hasPrefix(sentinel) || cursorOffset(title: title) != nil
    }
}
