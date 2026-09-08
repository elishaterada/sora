import Foundation

/// Scanning shared by the `<SORA_COMMAND>` and `<SORA_WEBPAGE>` text envelopes.
///
/// The system prompt asks for an envelope on its own with no other text, but
/// models routinely introduce it with a sentence and emit JSON with unescaped
/// quotes inside `command`. Both cases used to leave the raw protocol text in
/// the transcript, so the scanner tolerates them rather than the user seeing
/// Sora's wire format.
enum AgentEnvelope {
    static let repairInstruction = """
    Sora could not validate your previous action proposal. Nothing was executed.
    Answer the original request again. Emit at most ONE action: either
    <SORA_COMMAND>{"summary":"Short single-line summary","command":"single-line zsh command"}</SORA_COMMAND>
    or <SORA_WEBPAGE>{"summary":"Short single-line summary","url":"https://example.com/path"}</SORA_WEBPAGE>.
    or one valid <SORA_PROGRAM> save/run proposal as described in the system instructions.
    Use valid JSON: escape embedded double quotes and backslashes. Include the
    closing tag. Keep summary under 600 UTF-8 bytes and command under 4096 bytes.
    Only program script values may contain JSON-escaped newlines and tabs.
    Do not put control characters in other values.
    If no valid action is appropriate, give a plain-language answer without tags.
    """

    static func repairFeedback(for text: String, attempt: Int) -> String {
        var reasons: [String] = []
        let tags = ["COMMAND", "WEBPAGE", "PROGRAM"]
        if text.components(separatedBy: "<SORA_").count > 2 {
            reasons.append("Multiple actions were returned. Return only the first necessary action, then wait for its result.")
        }
        for tag in tags where text.contains("<SORA_" + tag + ">") {
            let closing = "</SORA_" + tag + ">"
            if !text.contains(closing) { reasons.append("Missing closing tag: " + closing) }
        }
        if let span = span(in: text, opening: "<SORA_COMMAND>", closing: "</SORA_COMMAND>"),
           let object = try? JSONSerialization.jsonObject(with: Data(span.json.utf8)) as? [String: Any] {
            if let command = object["command"] as? String {
                if command.utf8.count > 4096 { reasons.append("The command exceeds 4096 bytes. Split the task into smaller actions.") }
                if command.contains("\n") || command.contains("\r") || command.contains("\t") {
                    reasons.append("The command contains a newline or tab. Use a single-line command, e.g. python3 -c with JSON-escaped shell quotes, or split the work into smaller commands. Do not use a multiline heredoc.")
                }
            } else { reasons.append("The command field is missing or is not a string.") }
            if let summary = object["summary"] as? String, summary.utf8.count > 600 {
                reasons.append("The summary exceeds 600 bytes. Use a short sentence.")
            }
        }
        if reasons.isEmpty {
            reasons.append("Invalid JSON, unsupported action tag, or invalid required fields. Use exactly the documented schema and limits; do not introduce a new action type.")
        }
        if attempt > 1 {
            reasons.append("Repair failed again. Change approach: propose one short prerequisite or inspection command instead of regenerating the same complex action. Keep working toward the user's goal. If genuinely blocked, explain the specific blocker in plain text without action tags.")
        }
        return repairInstruction + "\n\nValidation feedback:\n" + reasons.joined(separator: "\n")
    }

    static func needsRepair(_ text: String) -> Bool {
        guard text.contains("<SORA_") || text.contains("</SORA_") else { return false }
        return AgentCommandProposalParser.match(text) == nil
            && AgentWebpageProposalParser.match(text) == nil
            && AgentProgramProposal.match(text) == nil
    }

    struct Span: Equatable {
        let json: String
        /// The message with the envelope removed.
        let prose: String
    }

    /// Finds one envelope anywhere in `text`. Two envelopes are ambiguous about
    /// which action was intended, so that is treated as no match.
    static func span(in text: String, opening: String, closing: String) -> Span? {
        // Mixed command/webpage proposals are as ambiguous as two commands.
        guard text.components(separatedBy: "<SORA_").count == 2,
              let start = text.range(of: opening),
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
