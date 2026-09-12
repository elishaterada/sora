import Foundation

enum CommandHistoryScope: Int, CaseIterable {
    case tab, folder, all
    var title: String {
        switch self { case .tab: return "This tab"; case .folder: return "This folder"; case .all: return "All history" }
    }
}

struct FuzzySearchMatch: Equatable {
    let score: Int
    let ranges: [NSRange]
}

enum FuzzySearch {
    static func match(_ query: String, in value: String) -> FuzzySearchMatch? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return FuzzySearchMatch(score: 0, ranges: []) }
        if let range = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let nsRange = NSRange(range, in: value)
            return FuzzySearchMatch(score: 10_000 - nsRange.location - value.count, ranges: [nsRange])
        }
        let wanted = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !wanted.isEmpty else { return FuzzySearchMatch(score: 0, ranges: []) }
        var units: [(Unicode.Scalar, NSRange, Bool)] = []
        var offset = 0, boundary = true
        for character in value {
            let text = String(character)
            let length = text.utf16.count
            let range = NSRange(location: offset, length: length)
            for scalar in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars {
                units.append((scalar, range, boundary))
            }
            offset += length
            boundary = character.isWhitespace || "/_-.:".contains(character)
        }
        var cursor = 0, score = 0, ranges: [NSRange] = []
        for scalar in wanted {
            guard cursor < units.count, let next = units[cursor...].firstIndex(where: { $0.0 == scalar }) else { return nil }
            score += (next == cursor ? 30 : 0) + (units[next].2 ? 20 : 0) - (next - cursor)
            if ranges.last != units[next].1 { ranges.append(units[next].1) }
            cursor = next + 1
        }
        return FuzzySearchMatch(score: score - value.count, ranges: ranges)
    }
}

struct CommandHistorySearchHit: Equatable {
    let command: String
    let directory: String
    let lastUsed: Date
    let uses: Int
    let match: FuzzySearchMatch
}
