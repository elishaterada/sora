import Foundation

/// zsh mirrors its live ZLE buffer to Sora through a sentinel-prefixed OSC 2
/// title. That buffer is the only authoritative prompt line: keystroke tracking
/// desyncs on paste, history recall, and completion, and the rendered grid has
/// no prompt boundary to scrape because `PS1` is empty.
enum ShellEditLine {
    static let sentinel = "\u{2400}sora-line\u{2400}"

    /// ASCII RS (0x1E). `command-blocks.zsh` binds this to the handoff widget.
    /// Delivered as Ctrl+6 through `ghostty_surface_key` — Ghostty's ctrlSeq
    /// maps that to RS. A bare codepoint writes nothing, and
    /// `ghostty_surface_text` is paste so it never runs bindkey.
    static let agentHandoffControl = UnicodeScalar(0x1E)!

    /// Returns the mirrored edit buffer, or nil when the title is a normal one.
    static func parse(title: String) -> String? {
        guard title.hasPrefix(sentinel) else { return nil }
        return String(title.dropFirst(sentinel.count))
    }

    static func isMirror(title: String) -> Bool {
        title.hasPrefix(sentinel)
    }
}
