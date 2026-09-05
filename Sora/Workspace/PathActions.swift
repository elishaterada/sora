import AppKit
import Foundation

/// Shared Finder / pasteboard actions for path and git context chips.
enum PathActions {
    static func reveal(_ url: URL) {
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url.standardizedFileURL])
        } else {
            NSWorkspace.shared.open(url.standardizedFileURL)
        }
    }

    static func copyPath(_ url: URL) {
        copy(url.standardizedFileURL.path)
    }

    static func copyDisplayPath(_ url: URL) {
        copy(StickyPromptBarModel.displayPath(for: url))
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func resolve(
        _ raw: String,
        relativeTo base: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}\"'`"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return nil }

        let url: URL
        if trimmed.hasPrefix("~") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else if let base {
            url = base.appendingPathComponent(trimmed)
        } else {
            return nil
        }

        let standardized = url.standardizedFileURL
        if fileManager.fileExists(atPath: standardized.path) {
            return standardized
        }
        // Absolute / home paths stay actionable so Reveal can open a parent.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return standardized
        }
        return nil
    }
}

enum TextSegment: Equatable {
    case text(String)
    case path(String, URL)
}

enum PathLinkParser {
    /// Finds filesystem paths in prose (absolute, `~/…`, or relative under `base`).
    static func segments(
        in text: String,
        relativeTo base: URL?,
        fileManager: FileManager = .default
    ) -> [TextSegment] {
        guard !text.isEmpty else { return [] }
        let pattern = #"(\/[^\s]+|~\/[^\s]+|(?<![A-Za-z0-9_])(?:[\w.-]+\/)+[\w.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [TextSegment] = []
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result.append(.text(ns.substring(with: NSRange(location: cursor, length: range.location - cursor))))
            }
            let token = ns.substring(with: range)
            if let url = PathActions.resolve(token, relativeTo: base, fileManager: fileManager) {
                result.append(.path(token, url))
            } else {
                result.append(.text(token))
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result.append(.text(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))))
        }
        return result.isEmpty ? [.text(text)] : result
    }
}
