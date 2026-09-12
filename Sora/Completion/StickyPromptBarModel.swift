import AppKit

enum StickyPromptBarModel {
    static func selectionReplacement(keyCode: UInt16, text: String, modifiers: NSEvent.ModifierFlags) -> String? {
        let mods = modifiers.intersection([.command, .control, .option, .shift])
        if [UInt16(51), 117].contains(keyCode), mods.isEmpty { return "" }
        if [UInt16(36), 76].contains(keyCode), mods == [.shift] { return "\n" }
        guard !mods.contains(.command), !mods.contains(.control), !text.isEmpty,
              ![UInt16(123), 124, 125, 126].contains(keyCode),
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    static func visibleLineCount(total: Int, maximumHeight: CGFloat, baseHeight: CGFloat = 112, lineHeight: CGFloat = 24) -> Int {
        min(max(1, total), max(1, Int((maximumHeight - baseHeight) / max(1, lineHeight)) + 1))
    }

    struct WrappedInput {
        var lines: [String]
        var starts: [Int]
        var cursorRow: Int
        var cursorPrefix: String
    }

    static func wrap(_ text: String, cursorOffset: Int, width: CGFloat,
                     measure: (String) -> CGFloat) -> WrappedInput {
        var lines: [String] = []
        var starts: [Int] = []
        var consumed = 0
        var cursorRow = 0
        var cursorPrefix = ""
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            let characters = Array(paragraph)
            var start = 0
            repeat {
                // Find the longest fitting prefix with logarithmic text shaping
                // calls, rather than reshaping every growing prefix per glyph.
                var lower = min(start + 1, characters.count)
                var upper = lower
                while upper < characters.count,
                      measure(String(characters[start..<upper])) <= max(1, width) {
                    lower = upper
                    upper = min(characters.count, start + max(1, (upper - start) * 2))
                }
                while lower < upper {
                    let middle = lower + (upper - lower + 1) / 2
                    if measure(String(characters[start..<middle])) <= max(1, width) {
                        lower = middle
                    } else {
                        upper = middle - 1
                    }
                }
                let line = String(characters[start..<lower])
                starts.append(consumed)
                lines.append(line)
                if consumed <= cursorOffset {
                    cursorRow = lines.count - 1
                    cursorPrefix = String(line.unicodeScalars.prefix(max(0, cursorOffset - consumed)))
                }
                consumed += line.unicodeScalars.count
                start = lower
            } while start < characters.count
            if paragraphIndex < paragraphs.count - 1 { consumed += 1 }
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
