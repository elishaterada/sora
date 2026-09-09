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
    private let worker: DispatchQueue
    private var inFlight = false
    private var latestRequest: Request?
    private var completedKey: Key?

    private struct Key: Equatable {
        var line: String
        var tracking: Bool
        var previous: String?
        var dismissed: Bool
        var cwd: URL
    }
    private struct Request {
        var key: Key
        var history: CommandHistoryStore
        var completion: () -> Void
    }

    init(worker: DispatchQueue = DispatchQueue(label: "dev.sora.completion", qos: .userInitiated)) {
        self.worker = worker
    }

    private func key(cwd: URL) -> Key {
        Key(line: buffer.text, tracking: buffer.isTracking, previous: lastSuccessfulCommand,
            dismissed: predictionDismissed, cwd: cwd)
    }

    /// Only one lookup runs at a time. While it runs, retain only the newest
    /// request; obsolete results can never replace the current suggestion.
    func refreshAsync(cwd: URL, history: CommandHistoryStore, completion: @escaping () -> Void) {
        let current = key(cwd: cwd)
        guard current != completedKey else { return }
        latestRequest = Request(key: current, history: history, completion: completion)
        startLatestRequest()
    }

    private func startLatestRequest() {
        guard !inFlight, let request = latestRequest else { return }
        guard request.key.tracking else { latestRequest = nil; return }
        inFlight = true
        let snapshot = CompletionSession(worker: worker)
        snapshot.buffer = buffer
        snapshot.lastSuccessfulCommand = lastSuccessfulCommand
        snapshot.predictionDismissed = predictionDismissed
        worker.async { [weak self] in
            // SQLite's connection is FULLMUTEX; these methods only read and do
            // not touch the store's @Published recent list.
            snapshot.refresh(cwd: request.key.cwd, history: request.history)
            let result = snapshot.suggestion
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if self.latestRequest?.key == request.key,
                   self.key(cwd: request.key.cwd) == request.key {
                    self.suggestion = result
                    self.completedKey = request.key
                    self.latestRequest = nil
                    request.completion()
                } else if self.latestRequest?.key == request.key {
                    self.latestRequest = nil
                }
                self.startLatestRequest()
            }
        }
    }

    private func invalidateLookup() {
        completedKey = nil
        latestRequest = nil
        suggestion = nil
    }

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
            invalidateLookup()
            return .accept(suffix)
        }

        invalidateLookup()
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
        invalidateLookup()
        if text.contains(where: { $0 == "\n" || $0 == "\r" }) {
            buffer.apply(.reset)
            suggestion = nil
            return
        }
        buffer.apply(.insert(text))
    }

    func stopTracking() {
        invalidateLookup()
        buffer.apply(.stopTracking)
        suggestion = nil
        predictionDismissed = true
    }

    func reset() {
        invalidateLookup()
        buffer.apply(.reset)
        suggestion = nil
    }

    func rememberSuccessfulCommand(_ command: String) {
        invalidateLookup()
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
