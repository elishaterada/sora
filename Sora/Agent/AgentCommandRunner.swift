import Foundation
import Darwin

struct AgentCommandResult: Codable, Equatable, Sendable {
    let command: String
    let directory: String
    let output: String
    let exitCode: Int32
    let interrupted: Bool
    let truncated: Bool
}

struct AgentProcessSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let startedAt: Date
    let observedAt: Date
    let lastOutputAt: Date?
    let bytesRead: Int
    let output: String
    let truncated: Bool
    let running: Bool
    var elapsed: Int { max(0, Int(observedAt.timeIntervalSince(startedAt))) }
    var status: String {
        if !running { return "Process ended" }
        if bytesRead == 0 { return "Running · \(elapsed)s · waiting for output" }
        return "Running · \(elapsed)s · \(bytesRead) bytes received" + (truncated ? " · excerpt retained" : "")
    }
}

/// How aggressively Sora auto-runs agent-proposed commands and webpage fetches.
enum AgentPermissionMode: String, CaseIterable, Identifiable, Sendable {
    case askForApproval
    case approveForMe
    case fullAccess

    var id: String { rawValue }

    static let defaultsKey = "ai.agentPermissionMode"

    var title: String {
        switch self {
        case .askForApproval: return "Ask for approval"
        case .approveForMe: return "Approve for me"
        case .fullAccess: return "Full access"
        }
    }

    var detail: String {
        switch self {
        case .askForApproval:
            return "Ask before running commands, native inspections or webpage fetches, unless you granted the same read for this task."
        case .approveForMe:
            return "Auto-run bounded native inspections inside the task folder and a fixed list of listing commands. Outside paths, credential-like files, webpages and other commands still ask."
        case .fullAccess:
            return "Run any proposed command and fetch any page without asking. Commands use your full file permissions."
        }
    }

    /// Status-bar / tooltip summary that matches the active policy.
    var statusHelp: String {
        switch self {
        case .askForApproval:
            return "Commands, inspections and webpages wait for approval, except explicit grants for the same native read in this task."
        case .approveForMe:
            return "Bounded native inspections in the task folder and listing commands run automatically. Outside paths, credential-like files, webpages and other commands still ask."
        case .fullAccess:
            return "Commands and webpages run without asking, with your full file permissions."
        }
    }

    var systemImage: String {
        switch self {
        case .askForApproval: return "hand.raised"
        case .approveForMe: return "shield.lefthalf.filled"
        case .fullAccess: return "exclamationmark.shield"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AgentPermissionMode {
        guard let raw = defaults.string(forKey: defaultsKey),
              let mode = AgentPermissionMode(rawValue: raw) else {
            return .askForApproval
        }
        return mode
    }
}

/// Deliberately narrow automatic permission. Everything else needs approval
/// unless the user chooses Full access. No substitutions, redirections, shell
/// functions, or arbitrary xargs targets.
enum AgentCommandPermission {
    static func allowsAutomatically(_ command: String) -> Bool {
        guard !command.isEmpty,
              command.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /._~-|*").contains($0) }) else { return false }
        let stages = command.components(separatedBy: "|")
        for (index, stage) in stages.enumerated() {
            let words = stage.split(separator: " ").map(String.init)
            guard let name = words.first else { return false }
            let args = Array(words.dropFirst())
            switch name {
            case "pwd": guard index == 0, args.isEmpty else { return false }
            case "ls", "du":
                guard index == 0 else { return false }
                let allowed = name == "ls" ? CharacterSet(charactersIn: "lahSrt1") : CharacterSet(charactersIn: "ahskmd0123456789")
                guard args.allSatisfy({ !$0.hasPrefix("-") || ($0.count > 1 && $0.dropFirst().unicodeScalars.allSatisfy(allowed.contains)) }) else { return false }
            case "find":
                guard index == 0, args.count >= 3,
                      let typeIndex = args.firstIndex(of: "-type"), typeIndex >= 1,
                      args[..<typeIndex].allSatisfy({ !$0.hasPrefix("-") }),
                      Array(args[typeIndex...]) == ["-type", "f", "-print0"]
                        || Array(args[typeIndex...]) == ["-type", "f", "-print"] else { return false }
            case "xargs": guard index > 0, args == ["-0", "du", "-h"] else { return false }
            case "sort": guard index > 0, args == ["-hr"] || args == ["-nr"] else { return false }
            case "head":
                guard index > 0, args.count == 1, args[0].hasPrefix("-"),
                      let count = Int(args[0].dropFirst()), (1...100).contains(count) else { return false }
            default: return false
            }
        }
        return true
    }

    static func shouldAutoRunCommand(_ command: String, mode: AgentPermissionMode) -> Bool {
        switch mode {
        case .askForApproval:
            return false
        case .approveForMe:
            return allowsAutomatically(command)
        case .fullAccess:
            return AgentCommandProposal.isValidCommand(command)
        }
    }

    static func shouldAutoFetchWebpage(mode: AgentPermissionMode) -> Bool {
        switch mode {
        case .askForApproval, .approveForMe:
            // Approve for me is a command allowlist only — webpages still ask.
            return false
        case .fullAccess:
            return true
        }
    }
}

/// The search path the user's own login shell uses.
///
/// A GUI app inherits launchd's minimal path, so agent commands could not see
/// Homebrew, pipx, mise, or anything else outside `/usr/bin`. The agent then
/// reported installed tools as missing and proposed reinstalling them. Agent
/// commands still run with no startup files; only the search path is borrowed.
enum LoginShellPath {
    static let beginMarker = "__SORA_PATH_BEGIN__"
    static let endMarker = "__SORA_PATH_END__"

    /// Used when the login shell cannot be asked. Homebrew's two prefixes cover
    /// Apple silicon and Intel installs.
    static let fallback = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolved once per launch: starting a login shell is not free, and the
    /// answer does not change while Sora runs.
    static let value: String = resolve() ?? fallback

    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = String(output[start.upperBound..<end.lowerBound])
        // A path with a newline or NUL is malformed and unsafe to pass on.
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\0") else { return nil }
        return value
    }

    static func resolve(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: TimeInterval = 5
    ) -> String? {
        // Interactive first: many users extend PATH in .zshrc, which a
        // non-interactive login shell never reads.
        for arguments in [["-ilc"], ["-lc"]] {
            let script = "printf '\(beginMarker)%s\(endMarker)' \"$PATH\""
            if let output = capture(shell: shell, arguments: arguments + [script], timeout: timeout),
               let path = parse(output) {
                return path
            }
        }
        return nil
    }

    private static func capture(shell: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Startup files chatter on stderr; only the marked stdout matters.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A separate noninteractive shell: output belongs to the agent, never to the
/// user's PTY. A process group lets Stop terminate pipelines as well as zsh.
final class AgentCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var interrupted = false
    private let outputLimit = 32_768
    private let searchPath: String
    private let handleID = UUID()
    private var startedAt: Date?
    private var lastOutputAt: Date?
    private var bytesRead = 0
    private var capturedOutput = Data()
    private var outputTruncated = false

    func snapshot() -> AgentProcessSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt else { return nil }
        return AgentProcessSnapshot(id: handleID, startedAt: startedAt, observedAt: Date(),
            lastOutputAt: lastOutputAt, bytesRead: bytesRead,
            output: String(decoding: capturedOutput, as: UTF8.self), truncated: outputTruncated, running: pid > 0)
    }

    init(searchPath: String = LoginShellPath.value) {
        self.searchPath = searchPath
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if pid > 0 {
            interrupted = true
            kill(-pid, SIGKILL)
        }
        lock.unlock()
    }

    func run(command: String, directory: URL, timeout: TimeInterval = 60) async throws -> AgentCommandResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.execute(command, directory: directory, timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func execute(_ command: String, directory: URL, timeout: TimeInterval) throws -> AgentCommandResult {
        let pipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["/bin/zsh", "-f", "-o", "pipefail", "-c", command].map { value in value.withCString { strdup($0) } }
        var values = ProcessInfo.processInfo.environment
        values["PATH"] = searchPath
        values["ZDOTDIR"] = "/dev/null"
        let environment = values.map { pair in "\(pair.key)=\(pair.value)".withCString { strdup($0) } }
        defer { (arguments + environment).forEach { free($0) } }
        var argv = arguments + [nil]
        var envp = environment + [nil]
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        var child: pid_t = 0
        let error = posix_spawn(&child, "/bin/zsh", &actions, &attributes, &argv, &envp)
        if error == 0 {
            pid = child
            startedAt = Date()
            // Stop may have arrived while spawn held the lock; kill before unlocking.
            if cancelled {
                interrupted = true
                kill(-child, SIGKILL)
            }
        }
        lock.unlock()
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        pipe.fileHandleForWriting.closeFile()
        // Drain concurrently with the timeout; retain only a bounded excerpt.
        let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        var output = Data()
        var truncated = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            let room = max(0, outputLimit - output.count)
            output.append(chunk.prefix(room))
            if chunk.count > room { truncated = true }
            lock.lock()
            bytesRead += chunk.count
            lastOutputAt = Date()
            capturedOutput = output
            outputTruncated = truncated
            lock.unlock()
        }
        pipe.fileHandleForReading.closeFile()
        // WNOWAIT retains the PID until cancellation can no longer target it.
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        lock.lock()
        pid = 0
        let wasInterrupted = interrupted
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        lock.unlock()
        deadline.cancel()
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return AgentCommandResult(command: command, directory: directory.path,
                                  output: String(decoding: output, as: UTF8.self), exitCode: code,
                                  interrupted: wasInterrupted, truncated: truncated)
    }
}
