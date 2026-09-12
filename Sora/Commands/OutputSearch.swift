import Foundation

enum OutputSearchScope: Int { case terminal, selectedBlock }

struct OutputSearchSnapshot: Sendable {
    let text: String
    let command: String?
    let capturedAt: Date
    let isExcerpt: Bool

    init(text: String, command: String? = nil, capturedAt: Date = Date()) {
        let copy = OutputSearchText.clipped(text, byteLimit: 1_000_000)
        self.text = copy.text
        self.command = command
        self.capturedAt = capturedAt
        isExcerpt = copy.truncated
    }
}

enum OutputSearchText {
    static let matchLimit = 10_000
    static func clipped(_ text: String, byteLimit: Int) -> (text: String, truncated: Bool) {
        var data = Data(text.utf8.prefix(byteLimit + 1))
        guard data.count > byteLimit else { return (text, false) }
        data.removeLast()
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return (String(decoding: data, as: UTF8.self), true)
    }

    struct Result: Equatable, Sendable {
        let text: String
        let matches: [NSRange]
        let hasMoreMatches: Bool
        let matchingLines: Int?
        var hasMoreLines = false
        func next(from index: Int?, previous: Bool) -> Int? {
            guard !matches.isEmpty else { return nil }
            guard let index, matches.indices.contains(index) else { return previous ? matches.count - 1 : 0 }
            return (index + (previous ? matches.count - 1 : 1)) % matches.count
        }
    }

    /// Literal, case-insensitive UTF-16 ranges match NSTextView's selection API.
    /// Filtering preserves the matching lines verbatim and never edits the source.
    static func search(_ source: String, query: String, matchingLinesOnly: Bool) -> Result {
        let needle = String(query.prefix(512))
        var display = source
        var lineCount: Int?
        var moreLines = false
        if matchingLinesOnly, !needle.isEmpty {
            var lines: [String] = []
            source.enumerateLines { line, stop in
                if line.range(of: needle, options: .caseInsensitive) != nil {
                    if lines.count == matchLimit { moreLines = true; stop = true }
                    else { lines.append(line) }
                }
            }
            lineCount = lines.count
            display = lines.joined(separator: "\n")
        }
        guard !needle.isEmpty else { return Result(text: display, matches: [], hasMoreMatches: false, matchingLines: lineCount) }
        let text = display as NSString
        var matches: [NSRange] = [], offset = 0
        while offset < text.length {
            let range = text.range(of: needle, options: .caseInsensitive, range: NSRange(location: offset, length: text.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if matches.count == matchLimit { return Result(text: display, matches: matches, hasMoreMatches: true, matchingLines: lineCount, hasMoreLines: moreLines) }
            matches.append(range)
            offset = NSMaxRange(range)
        }
        return Result(text: display, matches: matches, hasMoreMatches: false, matchingLines: lineCount, hasMoreLines: moreLines)
    }
}

/// One worker plus the newest pending request bounds rapid typing work. Native
/// terminal capture stays on the main thread; only immutable text crosses over.
final class OutputSearchWorker {
    private struct Request: Sendable {
        let revision: Int
        let source: String
        let query: String
        let filtered: Bool
    }
    private var revision = 0
    private var running = false
    private var pending: Request?
    var onResult: ((OutputSearchText.Result) -> Void)?
    func search(source: String, query: String, filtered: Bool) {
        revision += 1
        pending = Request(revision: revision, source: source, query: query, filtered: filtered)
        startNext()
    }
    func cancel() { revision += 1; pending = nil }
    private func startNext() {
        guard !running, let request = pending else { return }
        pending = nil
        running = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OutputSearchText.search(request.source, query: request.query, matchingLinesOnly: request.filtered)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                if request.revision == self.revision { self.onResult?(result) }
                self.startNext()
            }
        }
    }
}
