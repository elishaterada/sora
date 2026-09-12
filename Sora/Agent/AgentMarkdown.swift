import AppKit
import Foundation

/// One Markdown block ready for layout.
///
/// Foundation's Markdown parser records block structure in `presentationIntent`
/// but emits no newlines between blocks, so rendering the whole string as a
/// single `Text` runs headings, paragraphs, and list items together.
struct AgentMarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case listItem(marker: String, depth: Int)
        case codeBlock
        case blockQuote
    }

    let id: Int
    let kind: Kind
    let text: AttributedString

    /// Whether this block contains an explicit or detected link.
    var hasLinks: Bool {
        text.runs.contains { $0.link != nil }
    }
}

enum AgentMarkdown {
    /// Blocks in document order, or nil when the source cannot be parsed.
    /// `relativeTo` is the agent's working directory, used to resolve mentioned
    /// paths into openable links.
    static func blocks(
        _ source: String,
        streaming: Bool = false,
        relativeTo base: URL? = nil,
        fileManager: FileManager = .default
    ) -> [AgentMarkdownBlock]? {
        guard let attributed = attributed(
            source,
            streaming: streaming,
            relativeTo: base,
            fileManager: fileManager
        ) else { return nil }
        return split(attributed)
    }

    static func attributed(
        _ source: String,
        streaming: Bool = false,
        relativeTo base: URL? = nil,
        fileManager: FileManager = .default
    ) -> AttributedString? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var options = AttributedString.MarkdownParsingOptions()
        // Foundation's partial-failure policy keeps incomplete trailing syntax
        // visible, including an open code fence, while the full parser styles
        // every complete heading, list, quote, link, and code span immediately.
        // The previous inline-only streaming mode delayed all block formatting
        // until the response completed.
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible

        guard var attributed = try? AttributedString(
            markdown: source,
            options: options,
            baseURL: nil
        ) else {
            return nil
        }

        // Link before theming so path links pick up the same accent treatment
        // as Markdown links.
        linkPaths(&attributed, relativeTo: base, fileManager: fileManager)
        applyTheme(&attributed)
        return attributed
    }

    /// Turns filesystem paths the model mentions into `file://` links.
    /// `AgentMarkdownText` reveals those in Finder.
    private static func linkPaths(
        _ attributed: inout AttributedString,
        relativeTo base: URL?,
        fileManager: FileManager
    ) {
        var found: [(range: Range<AttributedString.Index>, url: URL)] = []

        for run in attributed.runs {
            // Never override an explicit Markdown link, and leave fenced blocks
            // alone so commands stay plain text to read and copy.
            guard run.link == nil, !isCodeBlock(run.presentationIntent) else { continue }
            let text = String(attributed[run.range].characters)

            if run.inlinePresentationIntent?.contains(.code) == true {
                // A whole code span is one token, so paths containing spaces
                // ("~/Downloads/My File.mp4") resolve here but not in prose.
                if let url = pathURL(text, relativeTo: base, fileManager: fileManager) {
                    found.append((run.range, url))
                }
                continue
            }

            var cursor = run.range.lowerBound
            for segment in PathLinkParser.segments(in: text, relativeTo: base, fileManager: fileManager) {
                switch segment {
                case .text(let value):
                    cursor = attributed.index(cursor, offsetByCharacters: value.count)
                case .path(let label, let url):
                    let end = attributed.index(cursor, offsetByCharacters: label.count)
                    // "in ~/Downloads:" — keep sentence punctuation out of the link.
                    let trailing = label.reversed().prefix { trailingPunctuation.contains($0) }.count
                    if trailing < label.count, fileManager.fileExists(atPath: url.path) {
                        let linkEnd = attributed.index(cursor, offsetByCharacters: label.count - trailing)
                        found.append((cursor..<linkEnd, url))
                    }
                    cursor = end
                }
            }
        }

        for entry in found {
            attributed[entry.range].link = entry.url
        }
    }

    private static let trailingPunctuation = Set(".,;:)]}\"'`")

    private static func pathURL(
        _ token: String,
        relativeTo base: URL?,
        fileManager: FileManager
    ) -> URL? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        // A bare word like `ffmpeg` is a command, not a path, even when a file
        // of that name happens to exist in the working directory.
        guard !trimmed.isEmpty, !trimmed.contains("\n"), trimmed.contains("/") else { return nil }
        guard let url = PathActions.resolve(trimmed, relativeTo: base, fileManager: fileManager) else {
            return nil
        }
        // `resolve` keeps absolute paths actionable even when missing, which
        // suits Reveal buttons. A link that opens nothing is worse than plain
        // text, so require the target to exist here.
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func isCodeBlock(_ intent: PresentationIntent?) -> Bool {
        intent?.components.contains { component in
            if case .codeBlock = component.kind { return true }
            return false
        } ?? false
    }

    /// Groups runs into blocks. Each block carries a distinct `PresentationIntent`
    /// identity, so a change of intent marks a boundary.
    private static func split(_ attributed: AttributedString) -> [AgentMarkdownBlock] {
        var blocks: [AgentMarkdownBlock] = []
        var pendingIntent: PresentationIntent?
        var pendingText = AttributedString()
        var started = false

        func flush() {
            guard started else { return }
            let kind = kind(for: pendingIntent)
            let text = trimmed(pendingText, preservingWhitespace: kind == .codeBlock)
            if !text.characters.isEmpty {
                blocks.append(AgentMarkdownBlock(id: blocks.count, kind: kind, text: text))
            }
        }

        for run in attributed.runs {
            let slice = AttributedString(attributed[run.range])
            if started, pendingIntent == run.presentationIntent {
                pendingText.append(slice)
                continue
            }
            flush()
            pendingIntent = run.presentationIntent
            pendingText = slice
            started = true
        }
        flush()
        return blocks
    }

    private static func kind(for intent: PresentationIntent?) -> AgentMarkdownBlock.Kind {
        guard let intent else { return .paragraph }

        var heading: Int?
        var isCodeBlock = false
        var isBlockQuote = false
        var ordinal: Int?
        var listDepth = 0
        // Components run innermost first, so the first list encountered owns the item.
        var immediateListIsOrdered: Bool?

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                heading = level
            case .codeBlock:
                isCodeBlock = true
            case .blockQuote:
                isBlockQuote = true
            case .listItem(let value):
                if ordinal == nil { ordinal = value }
            case .orderedList:
                listDepth += 1
                if immediateListIsOrdered == nil { immediateListIsOrdered = true }
            case .unorderedList:
                listDepth += 1
                if immediateListIsOrdered == nil { immediateListIsOrdered = false }
            default:
                break
            }
        }

        if isCodeBlock { return .codeBlock }
        if let heading { return .heading(level: heading) }
        if listDepth > 0 {
            let marker = immediateListIsOrdered == true ? "\(ordinal ?? 1)." : "•"
            return .listItem(marker: marker, depth: listDepth)
        }
        if isBlockQuote { return .blockQuote }
        return .paragraph
    }

    private static func trimmed(
        _ value: AttributedString,
        preservingWhitespace: Bool
    ) -> AttributedString {
        var result = value
        if preservingWhitespace {
            // Fenced blocks keep interior newlines; only drop the trailing one.
            while let last = result.characters.last, last == "\n" || last == "\r" {
                result.removeSubrange(result.index(beforeCharacter: result.endIndex)..<result.endIndex)
            }
            return result
        }
        while let first = result.characters.first, first.isWhitespace {
            result.removeSubrange(result.startIndex..<result.index(afterCharacter: result.startIndex))
        }
        while let last = result.characters.last, last.isWhitespace {
            result.removeSubrange(result.index(beforeCharacter: result.endIndex)..<result.endIndex)
        }
        return result
    }

    private static func applyTheme(_ attributed: inout AttributedString) {
        let bodySize = SoraTheme.terminalFontSize
        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let monoFont = SoraTheme.terminalFont
        let textColor = NSColor(SoraTheme.text)
        let mutedColor = NSColor.secondaryLabelColor
        let linkColor = SoraTheme.nsAccent
        let codeColor = SoraTheme.nsCodeInline

        attributed.font = bodyFont
        attributed.foregroundColor = textColor

        for run in attributed.runs {
            let range = run.range

            // Block styling first, inline styling second, so inline code and
            // links always win inside whatever block contains them.
            var headingSize: CGFloat?
            var headingWeight = NSFont.Weight.semibold
            var inCodeBlock = false

            for component in run.presentationIntent?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    headingWeight = level <= 2 ? .semibold : .medium
                    headingSize = bodySize + CGFloat(max(0, 3 - level))
                case .codeBlock:
                    inCodeBlock = true
                case .blockQuote:
                    attributed[range].foregroundColor = mutedColor
                default:
                    break
                }
            }

            if let headingSize {
                attributed[range].font = NSFont.systemFont(ofSize: headingSize, weight: headingWeight)
                attributed[range].foregroundColor = textColor
            } else if inCodeBlock {
                attributed[range].font = monoFont
                attributed[range].foregroundColor = textColor
            }

            if run.inlinePresentationIntent?.contains(.code) == true {
                // Tint the glyphs instead of boxing them: a filled highlight on
                // every identifier makes a paragraph hard to read. Inside a
                // heading the size carries the emphasis, so keep the text color.
                attributed[range].font = mono(
                    size: headingSize ?? bodySize,
                    weight: headingSize == nil ? .regular : headingWeight
                )
                if headingSize == nil {
                    attributed[range].foregroundColor = codeColor
                }
            }

            if run.link != nil {
                attributed[range].foregroundColor = linkColor
                attributed[range].underlineStyle = .single
            }
        }
    }

    private static func mono(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if size == SoraTheme.terminalFontSize, weight == .regular {
            return SoraTheme.terminalFont
        }
        return NSFont(name: weight == .regular ? "SFMono-Regular" : "SFMono-Semibold", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
