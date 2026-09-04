import Foundation

struct CompletionSuggestion: Equatable {
    enum Source: Equatable {
        case history
        case path
        case prediction
    }

    var insertSuffix: String
    var source: Source
    var displayText: String

    init(insertSuffix: String, source: Source, displayText: String? = nil) {
        self.insertSuffix = insertSuffix
        self.source = source
        self.displayText = displayText ?? insertSuffix
    }
}

struct HistoryCommandStat: Equatable {
    var command: String
    var lastCwd: URL
    var frequency: Int
    var lastUsed: Date
    var sameCwdCount: Int
}

enum CompletionEngine {
    static func suggest(
        line: String,
        cwd: URL,
        now: Date,
        history: [HistoryCommandStat],
        pathMatches: [PathCompleter.Match]
    ) -> CompletionSuggestion? {
        guard !line.isEmpty else { return nil }

        let (_, token) = PathCompleter.lastToken(in: line)
        let pathFirst = PathCompleter.looksLikePath(token)
        let pathSuggestion = pathSuggestion(token: token, matches: pathMatches)
        let historySuggestion = historySuggestion(line: line, cwd: cwd, now: now, history: history)

        if pathFirst {
            return pathSuggestion ?? historySuggestion
        }
        return historySuggestion ?? pathSuggestion
    }

    private static func historySuggestion(
        line: String,
        cwd: URL,
        now: Date,
        history: [HistoryCommandStat]
    ) -> CompletionSuggestion? {
        guard line.count >= 2 else { return nil }
        let gitRoot = GitRepository.root(containing: cwd)
        let ranked = history.compactMap { stat -> (HistoryCommandStat, Int)? in
            guard stat.command.hasPrefix(line), stat.command != line else { return nil }
            var score = min(stat.frequency, 25) * 2
            if stat.sameCwdCount > 0 || stat.lastCwd.path == cwd.path {
                score += 100
            }
            if let gitRoot, GitRepository.isInside(stat.lastCwd, root: gitRoot) {
                score += 40
            }
            let age = now.timeIntervalSince(stat.lastUsed)
            if age < 3600 { score += 20 }
            else if age < 86_400 { score += 10 }
            else if age < 604_800 { score += 5 }
            return (stat, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.lastUsed > rhs.0.lastUsed
        }
        guard let best = ranked.first else { return nil }
        let suffix = String(best.0.command.dropFirst(line.count))
        guard !suffix.isEmpty else { return nil }
        return CompletionSuggestion(insertSuffix: suffix, source: .history)
    }

    private static func pathSuggestion(
        token: String,
        matches: [PathCompleter.Match]
    ) -> CompletionSuggestion? {
        guard !token.isEmpty else { return nil }
        if !PathCompleter.looksLikePath(token), token.count < 2 {
            return nil
        }
        guard let best = matches.first else { return nil }
        let tokenMatches = best.token.hasPrefix(token)
            || best.token.lowercased().hasPrefix(token.lowercased())
        guard tokenMatches, best.token.count > token.count else { return nil }
        let suffix = String(best.token.dropFirst(token.count))
        guard !suffix.isEmpty else { return nil }
        return CompletionSuggestion(insertSuffix: suffix, source: .path)
    }
}
