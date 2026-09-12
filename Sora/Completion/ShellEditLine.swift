import Foundation

/// zsh mirrors its live ZLE buffer to Sora through a sentinel-prefixed OSC 2
/// title. That buffer is the only authoritative prompt line: keystroke tracking
/// desyncs on paste, history recall, and completion, and the rendered grid has
/// no prompt boundary to scrape because `PS1` is empty.
enum ShellEditLine {
    static let commandStartedTitle = "\u{2400}sora-command-started\u{2400}"
    static let multilineSentinel = "\u{2400}sora-multiline\u{2400}"
    static let inputSentinel = "\u{2400}sora-input\u{2400}"

    /// Preexec's original command, before the ordinary window title removes
    /// newlines. An empty result also supports the older readiness-only mark.
    static func startedCommand(title: String) -> String? {
        if title.hasPrefix("sora-command;1;") {
            return String(title.dropFirst("sora-command;1;".count)).removingPercentEncoding
        }
        guard title.hasPrefix(commandStartedTitle) else { return nil }
        return decodeTransport(String(title.dropFirst(commandStartedTitle.count)))
    }

    private static func decodeTransport(_ text: String) -> String {
        text.replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%09", with: "\t")
            .replacingOccurrences(of: "%0D", with: "\r")
            .replacingOccurrences(of: "%1B", with: "\u{1B}")
            .replacingOccurrences(of: "%07", with: "\u{07}")
            .replacingOccurrences(of: "%25", with: "%")
    }

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
        let decoded = encoded ? decodeTransport(text) : text
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

/// Reassembles ordered, bounded title messages before exposing a shell snapshot.
struct ShellTitleAssembler {
    private var parts: [String] = []
    private var expected = 0

    mutating func consume(_ title: String) -> String? {
        guard title.hasPrefix("sora-chunk;") else { return title }
        let fields = title.split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let index = Int(fields[1]), let total = Int(fields[2]),
              total > 0, total <= 100_000, index >= 0, index < total else {
            parts = []; expected = 0
            return nil
        }
        if index == 0 { parts = []; expected = total }
        guard total == expected, index == parts.count else {
            parts = []; expected = 0
            return nil
        }
        parts.append(String(fields[3]))
        guard parts.count == total else { return nil }
        let result = parts.joined()
        parts = []; expected = 0
        return result
    }
}

/// Shell-reported display context is never interpreted as a local file URL
/// when a remote client owns the terminal. The process check also covers SSH
/// sessions with no integration installed on the server.
struct ShellContextReport: Equatable {
    static let prefix = "sora-context;"
    let shell: String
    let isRemote: Bool
    let host: String
    let path: String

    static func parse(_ title: String) -> Self? {
        guard title.hasPrefix(prefix), title.utf8.count <= 24_000 else { return nil }
        let fields = title.split(separator: ";", maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6, fields[1] == "1", ["zsh", "bash"].contains(fields[2]),
              ["local", "remote"].contains(fields[3]),
              let host = String(fields[4]).removingPercentEncoding,
              let path = String(fields[5]).removingPercentEncoding,
              !host.isEmpty, host.utf8.count <= 255, path.hasPrefix("/"), path.utf8.count <= 16_384,
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return Self(shell: String(fields[2]), isRemote: fields[3] == "remote", host: host, path: path)
    }

    static func isRemoteClient(_ executable: String?) -> Bool {
        ["ssh", "mosh", "mosh-client", "telnet"].contains(executable ?? "")
    }

    static func isRemote(report: Self?, foreground: String?, reportedPID: UInt64? = nil, foregroundPID: UInt64? = nil) -> Bool {
        let sameProcess = reportedPID == nil || foregroundPID == nil || reportedPID == foregroundPID
        return isRemoteClient(foreground) || (sameProcess && report?.isRemote == true)
    }

    static func displayRemote(report: Self?) -> String {
        guard let report, report.isRemote else { return "Remote terminal" }
        return "\(report.host):\(report.path)"
    }
}
