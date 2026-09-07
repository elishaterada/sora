import Foundation

enum PromptIntent: Equatable {
    case shell
    case agent
}

enum PromptSubmission: Equatable {
    case shell
    case agent(String)
}

/// Local router for Return. Prefer shell for real executables and shell syntax;
/// send conversational cues and *unknown* commands to the agent so zsh never
/// owns a guaranteed `command not found`.
enum PromptIntentClassifier {
    private static let conversationalStarts = [
        "can you ", "could you ", "would you ", "will you ", "help me ", "please ",
        "how do ", "how can ", "how should ", "how many ", "how much ", "how long ",
        "how often ", "how far ", "what is ", "what are ", "what does ", "what should ",
        "why is ", "why does ", "where is ", "where can ", "when should ", "who is ",
        "explain ", "summarize ", "describe ", "tell me ", "write me ", "show me ",
        "fix this ", "debug this ", "review this "
    ]

    static func intent(
        for line: String,
        shellCommandKnown: Bool = false,
        commandExists: (String) -> Bool = { ShellCommandResolver.isResolvable($0) }
    ) -> PromptIntent {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .shell }
        if explicitQuestion(in: value) != nil { return .agent }

        if shellCommandKnown { return .shell }

        // Clear shell syntax stays with the shell even when a token is missing —
        // the user is writing a pipeline/path, not chatting.
        if hasShellSyntax(value) { return .shell }

        let lower = value.lowercased()
        if conversationalStarts.contains(where: lower.hasPrefix) {
            return .agent
        }

        // Catch-all: unknown primary command → agent (install hints, paraphrase,
        // etc.) instead of `zsh: command not found`. Cmd+Return forces shell.
        if !commandExists(value) { return .agent }
        return .shell
    }

    static func submission(
        for line: String,
        forceShell: Bool = false,
        allowImplicitAgent: Bool = true,
        shellCommandKnown: Bool = false,
        commandExists: (String) -> Bool = { ShellCommandResolver.isResolvable($0) }
    ) -> PromptSubmission {
        if forceShell { return .shell }
        if let explicit = explicitQuestion(in: line) { return .agent(explicit) }
        guard allowImplicitAgent else { return .shell }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return intent(for: line, shellCommandKnown: shellCommandKnown, commandExists: commandExists) == .agent
            ? .agent(trimmed)
            : .shell
    }

    private static func explicitQuestion(in line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        guard lower.hasPrefix("/agent ") else { return nil }
        let question = String(value.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    /// Structural shell — not "is this a known binary name".
    private static func hasShellSyntax(_ line: String) -> Bool {
        if line.hasPrefix("./") || line.hasPrefix("../") || line.hasPrefix("/") || line.hasPrefix("~") {
            return true
        }
        if line.range(of: #"(^|\s)(\||&&|\|\||;|>|<|\$\(|`)"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
