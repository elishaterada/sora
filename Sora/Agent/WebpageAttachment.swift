import Foundation

struct WebpageAttachment: Codable, Equatable, Sendable {
    let url: URL
    let title: String
    let text: String
    let fetchedAt: Date
    let isExcerpt: Bool
}

/// Static HTML-to-text extraction only. Never renders HTML or loads resources.
/// The preview is the exact snapshot supplied to the model, not a browser view.
enum WebpageText {
    static let maxTextBytes = 50_000

    static func extract(_ source: String, url: URL, isHTML: Bool) throws -> WebpageAttachment {
        let title: String
        var text = source
        if isHTML {
            text = replacing(#"(?s)<!--.*?(?:-->|$)"#, in: text, with: " ")
            let titlePattern = try NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#)
            if let match = titlePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                title = String(normalize(decodeEntities(String(text[range]))).prefix(300))
            } else { title = url.host ?? "Webpage" }
            text = replacing(#"(?is)<(script|style|noscript|template|svg|head|title)\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?(?:</\1\s*>|$)"#, in: text, with: " ")
            text = replacing(#"(?is)</?(?:p|div|section|article|h[1-6]|li|ul|ol|br|hr|tr|header|footer|main)\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, in: text, with: "\n")
            // Quoted attribute values may themselves contain > characters.
            text = replacing(#"(?s)<(?:[^>"']|"[^"]*"|'[^']*')*>"#, in: text, with: " ")
            text = decodeEntities(text)
        } else { title = url.host ?? "Webpage" }
        text = normalize(text)
        guard !text.isEmpty else { throw WebpageError.empty }
        let excerpt = text.utf8.count > maxTextBytes
        if excerpt {
            // Trim at a scalar boundary without introducing replacement characters.
            var bytes = 0
            text = String(String.UnicodeScalarView(text.unicodeScalars.prefix { scalar in
                bytes += scalar.utf8.count
                return bytes <= maxTextBytes
            }))
        }
        return WebpageAttachment(url: url, title: title, text: text, fetchedAt: Date(), isExcerpt: excerpt)
    }

    private static func normalize(_ value: String) -> String {
        value.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func decodeEntities(_ value: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
                     "hellip": "…", "copy": "©", "reg": "®", "trade": "™", "bull": "•"]
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#X[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);"#)
        let source = value as NSString
        let result = NSMutableString(string: value)
        for match in regex.matches(in: value, range: NSRange(location: 0, length: source.length)).reversed() {
            let entity = source.substring(with: match.range(at: 1))
            var replacement = named[entity]
            if entity.hasPrefix("#") {
                let hex = entity.lowercased().hasPrefix("#x")
                if let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(number), number != 0 { replacement = String(scalar) }
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}

struct AgentWebpageProposal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending, approved, dismissed, failed
    }

    let summary: String
    let url: String
    var status: Status = .pending
}

/// Agent-owned HTTPS fetch. Sora fetches a static text snapshot; the model never
/// browses with cookies or executes page scripts.
enum AgentWebpageProposalParser {
    static let openingTag = "<SORA_WEBPAGE>"
    static let closingTag = "</SORA_WEBPAGE>"

    private struct Payload: Decodable {
        let summary: String
        let url: String
    }

    static func parse(_ text: String) -> AgentWebpageProposal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(openingTag), value.hasSuffix(closingTag) else { return nil }
        let jsonStart = value.index(value.startIndex, offsetBy: openingTag.count)
        let jsonEnd = value.index(value.endIndex, offsetBy: -closingTag.count)
        guard jsonStart <= jsonEnd else { return nil }
        let json = String(value[jsonStart..<jsonEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return nil }
        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = payload.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.utf8.count <= 600,
              summary.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      return false
                  default:
                      return true
                  }
              }),
              (try? WebpageFetcher.url(url)) != nil
        else { return nil }
        return AgentWebpageProposal(summary: summary, url: url)
    }

    static func isStreamingEnvelope(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return openingTag.hasPrefix(value) || value.hasPrefix(openingTag)
    }
}
