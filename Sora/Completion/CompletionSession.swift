import AppKit
import Foundation

enum CompletionKeyResult: Equatable {
    case accept(String)
    case passThrough
}

/// Tracks the current prompt line from keystrokes and ranks a single suggestion.
/// The PTY remains the source of truth for the shell; this buffer is a best-effort
/// overlay that resets whenever the cursor is likely to have left the line.
final class CompletionSession {
    private(set) var buffer = PromptBuffer()
    private(set) var suggestion: CompletionSuggestion?
    private(set) var lastSuccessfulCommand: String?
    private var predictionDismissed = false

    func applyMouseFocus(isShellPromptReady: Bool) {
        if let event = PromptEvent.mouseFocusEvent(isShellPromptReady: isShellPromptReady, buffer: buffer) {
            buffer.apply(event)
            if !buffer.isTracking {
                suggestion = nil
                predictionDismissed = true
            }
        }
    }

    func handleKeyDown(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> CompletionKeyResult {
        if PromptEvent.isAcceptKey(keyCode: keyCode, modifiers: modifiers),
           let suggestion {
            buffer.apply(.insert(suggestion.insertSuffix))
            let suffix = suggestion.insertSuffix
            self.suggestion = nil
            return .accept(suffix)
        }

        if let event = PromptEvent.from(keyCode: keyCode, characters: characters, modifiers: modifiers) {
            buffer.apply(event)
            if keyCode == PromptEvent.escape
                || keyCode == PromptEvent.leftArrow
                || keyCode == PromptEvent.upArrow
                || keyCode == PromptEvent.downArrow {
                predictionDismissed = true
            }
        }
        if !buffer.isTracking {
            suggestion = nil
        }
        return .passThrough
    }

    func handlePaste(_ text: String) {
        if text.contains(where: { $0 == "\n" || $0 == "\r" }) {
            buffer.apply(.reset)
            suggestion = nil
            return
        }
        buffer.apply(.insert(text))
    }

    func stopTracking() {
        buffer.apply(.stopTracking)
        suggestion = nil
        predictionDismissed = true
    }

    func reset() {
        buffer.apply(.reset)
        suggestion = nil
    }

    func rememberSuccessfulCommand(_ command: String) {
        lastSuccessfulCommand = command
        predictionDismissed = false
    }

    func refresh(cwd: URL, history: CommandHistoryStore, now: Date = Date()) {
        guard buffer.isTracking else {
            suggestion = nil
            return
        }
        let line = buffer.text
        if line.isEmpty {
            suggestion = emptyPromptSuggestion(cwd: cwd, history: history, now: now)
            return
        }

        let (_, token) = PathCompleter.lastToken(in: line)
        let pathMatches: [PathCompleter.Match]
        if PathCompleter.looksLikePath(token) || token.count >= 2 {
            pathMatches = PathCompleter.matches(token: token, cwd: cwd)
        } else {
            pathMatches = []
        }

        let stats: [HistoryCommandStat]
        if line.count >= 2 {
            stats = (try? history.prefixStats(prefix: line, cwd: cwd)) ?? []
        } else {
            stats = []
        }

        suggestion = CompletionEngine.suggest(
            line: line,
            cwd: cwd,
            now: now,
            history: stats,
            pathMatches: pathMatches
        )
    }

    private func emptyPromptSuggestion(
        cwd: URL,
        history: CommandHistoryStore,
        now: Date
    ) -> CompletionSuggestion? {
        guard !predictionDismissed, let previous = lastSuccessfulCommand else {
            return nil
        }
        let stats = (try? history.transitionStats(previous: previous, cwd: cwd)) ?? []
        return NextCommandEngine.suggest(
            previous: previous,
            cwd: cwd,
            now: now,
            transitions: stats
        )
    }
}
