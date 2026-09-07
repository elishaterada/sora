import Foundation

enum StickyPromptBarModel {
    struct WrappedInput {
        var lines: [String]
        var starts: [Int]
        var cursorRow: Int
        var cursorPrefix: String
    }

    static func wrap(_ text: String, cursorOffset: Int, width: CGFloat,
                     measure: (String) -> CGFloat) -> WrappedInput {
        var lines = [""]
        var starts = [0]
        var consumed = 0
        var cursorRow = 0
        var cursorPrefix = ""
        for character in text {
            let value = String(character)
            if character == "\n" {
                lines.append("")
                starts.append(consumed + value.unicodeScalars.count)
            } else {
                if !lines[lines.count - 1].isEmpty && measure(lines[lines.count - 1] + value) > max(1, width) {
                    lines.append("")
                    starts.append(consumed)
                    if consumed == cursorOffset {
                        cursorRow = lines.count - 1
                        cursorPrefix = ""
                    }
                }
                lines[lines.count - 1] += value
            }
            consumed += value.unicodeScalars.count
            if consumed <= cursorOffset {
                cursorRow = lines.count - 1
                cursorPrefix = lines.last ?? ""
            }
        }
        return WrappedInput(lines: lines, starts: starts, cursorRow: cursorRow, cursorPrefix: cursorPrefix)
    }

    static func selectedText(_ text: String, range: Range<Int>) -> String {
        String(text.unicodeScalars.dropFirst(max(0, range.lowerBound)).prefix(max(0, range.count)))
    }

    static func hitOffset(in line: String, x: CGFloat, measure: (String) -> CGFloat) -> Int {
        var prefix = ""
        var offset = 0
        for character in line {
            let next = prefix + String(character)
            if x < (measure(prefix) + measure(next)) / 2 { return offset }
            prefix = next
            offset += String(character).unicodeScalars.count
        }
        return offset
    }

    /// Suggestions never become part of the displayed shell buffer.
    static func inputText(buffer: String, prediction: String?) -> String {
        buffer.isEmpty ? (prediction ?? "") : buffer
    }

    /// Scrollbar is pinned to the live prompt when the viewport ends at `total`.
    static func isViewingLivePrompt(total: UInt64, offset: UInt64, len: UInt64) -> Bool {
        total == 0 || offset + len >= total
    }

    static func displayPath(for url: URL?) -> String {
        guard let url else { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return url.lastPathComponent
    }
}
