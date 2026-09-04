import Foundation

enum PromptIntent: Equatable {
    case shell
    case agent
}

enum PromptSubmission: Equatable {
    case shell
    case agent(String)
}

/// A conservative, local-only router. It never calls a model and only chooses
/// AI when a line has a clear conversational cue. Ambiguous input remains shell.
enum PromptIntentClassifier {
    private static let commandNames: Set<String> = [
        "alias", "awk", "bat", "brew", "bun", "cargo", "cat", "cd", "chmod", "chown", "clear", "cmp",
        "code", "cp", "curl", "cut", "date", "defaults", "df", "diff", "dig", "docker", "du", "echo",
        "env", "exec", "exit", "export", "fd", "find", "git", "go", "grep", "head", "history", "hostname",
        "jq", "kill", "less", "ln", "ls", "make", "man", "mkdir", "mv", "nano", "node", "npm", "npx",
        "open", "pbcopy", "pbpaste", "ping", "pip", "pip3", "pnpm", "printenv", "printf", "ps", "pwd",
        "python", "python3", "rg", "rm", "rmdir", "rsync", "ruby", "sed", "sleep", "sort", "source",
        "ssh", "stat", "sudo", "swift", "tail", "tar", "tee", "time", "top", "touch", "tr", "tree",
        "uname", "uniq", "unzip", "vim", "wc", "which", "whoami", "xargs", "yarn", "zip", "zsh"
    ]
    private static let conversationalStarts = [
        "can you ", "could you ", "would you ", "will you ", "help me ", "please ",
        "how do ", "how can ", "how should ", "what is ", "what are ", "what does ", "what should ",
        "why is ", "why does ", "where is ", "where can ", "when should ", "who is ",
        "explain ", "summarize ", "describe ", "tell me ", "write me ", "show me ",
        "fix this ", "debug this ", "review this "
    ]

    static func intent(for line: String) -> PromptIntent {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .shell }
        if explicitQuestion(in: value) != nil { return .agent }
        guard value.split(whereSeparator: \.isWhitespace).count >= 3 else { return .shell }
        let lower = value.lowercased()
        guard !looksLikeShell(value) else { return .shell }
        if lower.hasSuffix("?") || conversationalStarts.contains(where: lower.hasPrefix) { return .agent }
        return .shell
    }

    static func submission(for line: String, forceShell: Bool = false) -> PromptSubmission {
        if forceShell { return .shell }
        if let explicit = explicitQuestion(in: line) { return .agent(explicit) }
        return intent(for: line) == .agent
            ? .agent(line.trimmingCharacters(in: .whitespacesAndNewlines))
            : .shell
    }

    private static func explicitQuestion(in line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        guard lower.hasPrefix("/agent ") else { return nil }
        let question = String(value.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    private static func looksLikeShell(_ line: String) -> Bool {
        if line.hasPrefix("./") || line.hasPrefix("../") || line.hasPrefix("/") || line.hasPrefix("~") { return true }
        if line.range(of: #"(^|\s)(\||&&|\|\||;|>|<|\$\(|`)"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { return true }
        let first = line.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        return commandNames.contains(first)
    }
}
