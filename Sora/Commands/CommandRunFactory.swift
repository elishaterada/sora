import Foundation

enum CommandRunFactory {
    /// Builds a `CommandRun` from Ghostty OSC 133 D (`command_finished`) plus
    /// the OSC 2 title Ghostty's zsh integration writes in preexec.
    ///
    /// Returns nil for the initial unmatched OSC 133 D (`exit_code < 0`) and
    /// for empty command text so we do not store prompt-only events.
    static func make(
        command: String,
        cwd: URL?,
        exitCode: Int16,
        durationNanos: UInt64,
        now: Date = Date()
    ) -> CommandRun? {
        guard exitCode >= 0 else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isWorkingDirectoryTitle(trimmed, cwd: cwd) {
            return nil
        }
        let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser
        let duration = TimeInterval(durationNanos) / 1_000_000_000
        return CommandRun(
            id: UUID(),
            command: trimmed,
            cwd: directory,
            startedAt: now.addingTimeInterval(-duration),
            finishedAt: now,
            exitCode: Int(exitCode),
            durationNanos: durationNanos
        )
    }

    static func isWorkingDirectoryTitle(_ command: String, cwd: URL?) -> Bool {
        if command.hasPrefix("~") && !command.contains(" ") {
            return true
        }
        if command.hasPrefix("…/") && !command.contains(" ") {
            return true
        }
        guard let cwd else { return false }
        if command == cwd.path { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if command == cwd.path.replacingOccurrences(of: home, with: "~") {
            return true
        }
        return false
    }
}
