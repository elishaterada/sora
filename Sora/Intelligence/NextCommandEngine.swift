import Foundation

struct TransitionStat: Equatable {
    var next: String
    var lastCwd: URL
    var frequency: Int
    var lastUsed: Date
    var sameCwdCount: Int
}

enum NextCommandEngine {
    /// Ranks the most likely next command after a successful `previous` command.
    /// Empty-prompt only; prefix completion handles typed input.
    static func suggest(
        previous: String,
        cwd: URL,
        now: Date,
        transitions: [TransitionStat]
    ) -> CompletionSuggestion? {
        guard !previous.isEmpty else { return nil }
        let gitRoot = GitRepository.root(containing: cwd)
        let ranked = transitions.compactMap { stat -> (TransitionStat, Int)? in
            guard !stat.next.isEmpty else { return nil }
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
        return CompletionSuggestion(
            insertSuffix: best.0.next,
            source: .prediction,
            displayText: "→ \(best.0.next)"
        )
    }
}
