import Foundation

/// Scanning shared by the `<SORA_COMMAND>` and `<SORA_WEBPAGE>` text envelopes.
///
/// The system prompt asks for an envelope on its own with no other text, but
/// models routinely introduce it with a sentence and emit JSON with unescaped
/// quotes inside `command`. Both cases used to leave the raw protocol text in
/// the transcript, so the scanner tolerates them rather than the user seeing
/// Sora's wire format.
enum AgentEnvelope {
    struct Span: Equatable {
        let json: String
        /// The message with the envelope removed.
        let prose: String
    }

    /// Finds one envelope anywhere in `text`. Two envelopes are ambiguous about
    /// which action was intended, so that is treated as no match.
    static func span(in text: String, opening: String, closing: String) -> Span? {
        guard let start = text.range(of: opening),
              let end = text.range(of: closing, range: start.upperBound..<text.endIndex),
              text.range(of: opening, range: start.upperBound..<text.endIndex) == nil
        else { return nil }

        let json = String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let before = text[text.startIndex..<start.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text[end.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Join as separate paragraphs; the envelope stood between them.
        let prose = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Span(json: json, prose: prose)
    }

    /// True when `text` holds an opening tag, whether or not it is readable.
    static func hasOpeningTag(_ text: String, opening: String) -> Bool {
        text.range(of: opening) != nil
    }

    /// Text that is safe to show mid-stream: everything before the envelope
    /// starts. Returns nil when no envelope, complete or partial, has begun.
    static func proseBeforeEnvelope(in text: String, opening: String) -> String? {
        if let range = text.range(of: opening) {
            return String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A tag arriving one chunk at a time ends with part of the opening tag.
        let longestPartial = min(opening.count - 1, text.count)
        guard longestPartial > 0 else { return nil }
        for length in stride(from: longestPartial, through: 1, by: -1) where opening.hasPrefix(text.suffix(length)) {
            return String(text.dropLast(length)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Reads `keys`, in the order the prompt specifies them, from a flat JSON
    /// object of string values. Unlike `JSONDecoder` this tolerates unescaped
    /// quotes in a value, which models produce constantly for shell one-liners
    /// such as `/bin/bash -c "$(curl …)"`. Only used after strict decoding
    /// fails, and the recovered command is still shown for approval.
    static func recoverStringValues(json: String, keys: [String]) -> [String: String]? {
        guard !keys.isEmpty else { return nil }
        var values: [String: String] = [:]
        var cursor = json.startIndex

        for (index, key) in keys.enumerated() {
            guard let opening = json.range(
                of: "\"\(key)\"\\s*:\\s*\"",
                options: .regularExpression,
                range: cursor..<json.endIndex
            ) else { return nil }

            let valueStart = opening.upperBound
            let valueEnd: String.Index
            if index + 1 < keys.count {
                guard let separator = json.range(
                    of: "\"\\s*,\\s*\"\(keys[index + 1])\"\\s*:\\s*\"",
                    options: .regularExpression,
                    range: valueStart..<json.endIndex
                ) else { return nil }
                valueEnd = separator.lowerBound
                cursor = separator.lowerBound
            } else {
                guard let tail = json.range(
                    of: "\"\\s*\\}?\\s*$",
                    options: [.regularExpression, .backwards],
                    range: valueStart..<json.endIndex
                ) else { return nil }
                valueEnd = tail.lowerBound
                cursor = json.endIndex
            }

            guard valueStart <= valueEnd else { return nil }
            values[key] = unescape(String(json[valueStart..<valueEnd]))
        }
        return values
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            guard escaped else {
                if character == "\\" { escaped = true } else { result.append(character) }
                continue
            }
            switch character {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "/": result.append("/")
            default:
                result.append("\\")
                result.append(character)
            }
            escaped = false
        }
        if escaped { result.append("\\") }
        return result
    }
}
