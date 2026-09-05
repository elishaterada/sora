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

/// Deliberately narrow automatic permission. Everything else needs approval.
/// No substitutions, redirections, shell functions, or arbitrary xargs targets.
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
}

/// A separate noninteractive shell: output belongs to the agent, never to the
/// user's PTY. A process group lets Stop terminate pipelines as well as zsh.
final class AgentCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var interrupted = false
    private let outputLimit = 32_768

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
        values["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        values["ZDOTDIR"] = "/dev/null"
        let environment = values.map { pair in "\(pair.key)=\(pair.value)".withCString { strdup($0) } }
        defer { (arguments + environment).forEach { free($0) } }
        var argv = arguments + [nil]
        var envp = environment + [nil]
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        var child: pid_t = 0
        let error = posix_spawn(&child, "/bin/zsh", &actions, &attributes, &argv, &envp)
        if error == 0 { pid = child }
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
