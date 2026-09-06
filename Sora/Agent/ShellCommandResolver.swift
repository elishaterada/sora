import Foundation

/// Whether a typed line's primary command can run in the agent/user shell PATH.
///
/// Used as the catch-all before Return: unknown commands go to the agent instead
/// of falling through to `zsh: command not found`. Builtins and keywords count
/// as resolvable even when they are not files on disk. User aliases and shell
/// functions are invisible here — Cmd+Return still forces the shell.
enum ShellCommandResolver {
    /// zsh builtins and reserved words that are not expected as PATH files.
    static let builtins: Set<String> = [
        "[", "[[", "alias", "bg", "bindkey", "break", "builtin", "bye", "case", "cd",
        "chdir", "command", "continue", "declare", "dirs", "disable", "do", "done",
        "echo", "elif", "else", "emulate", "enable", "esac", "eval", "exec", "exit",
        "export", "false", "fc", "fg", "fi", "float", "for", "foreach", "function",
        "getopts", "hash", "history", "if", "integer", "jobs", "kill", "let", "local",
        "logout", "noglob", "nocorrect", "popd", "print", "printf", "pushd", "pwd",
        "read", "readonly", "return", "select", "set", "setopt", "shift", "source",
        "suspend", "test", "then", "time", "times", "trap", "true", "type", "typeset",
        "ulimit", "umask", "unalias", "unfunction", "unset", "unsetopt", "until",
        "wait", "whence", "where", "which", "while", "."
    ]

    static func isResolvable(
        _ line: String,
        path: String = LoginShellPath.value,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let command = primaryCommand(in: line) else { return true }
        if builtins.contains(command) { return true }

        if command.hasPrefix("/") || command.hasPrefix("./") || command.hasPrefix("../")
            || command.hasPrefix("~") || command.contains("/")
        {
            let expanded = (command as NSString).expandingTildeInPath
            return isExecutable(expanded, fileManager: fileManager)
        }

        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(command)
                .path
            if isExecutable(candidate, fileManager: fileManager) {
                return true
            }
        }
        return false
    }

    /// First command word, skipping leading `NAME=value` assignments.
    static func primaryCommand(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, isEnvAssignment(first) {
            words.removeFirst()
        }
        guard let raw = words.first, !raw.isEmpty else { return nil }

        // `command -v foo` / `builtin cd` — peel one trusted wrapper.
        // Do not peel `sudo` here: `sudo -u user cmd` would otherwise treat
        // `user` as the command.
        if raw == "command" || raw == "builtin" || raw == "noglob" || raw == "nocorrect" {
            let rest = words.dropFirst().filter { !$0.hasPrefix("-") }
            if let nested = rest.first {
                return nested
            }
        }
        return raw
    }

    private static func isEnvAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }

    private static func isExecutable(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}
