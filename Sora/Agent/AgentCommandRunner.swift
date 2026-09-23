import Foundation
import Darwin

struct AgentCommandResult: Codable, Equatable, Sendable {
    let command: String
    let directory: String
    let output: String
    let exitCode: Int32
    let interrupted: Bool
    let truncated: Bool
    var userInterrupted: Bool? = nil
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
    var awaitingInput: Bool? = nil
    var elapsed: Int { max(0, Int(observedAt.timeIntervalSince(startedAt))) }
    var status: String {
        if !running { return "Process ended" }
        if awaitingInput == true { return "Your turn · agent is waiting" }
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

/// A private terminal for the approved command. Apple's script utility owns the
/// controlling PTY; Sora supplies input and captures bounded output, without
/// borrowing the user's shell or implementing a terminal emulator.
final class AgentCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var interrupted = false
    private var terminalInterruptRequested = false
    private let outputLimit = 32_768
    private let searchPath: String
    private let handleID = UUID()
    private var startedAt: Date?
    private var lastOutputAt: Date?
    private var bytesRead = 0
    private var capturedOutput = Data()
    private var outputTruncated = false
    private var inputHandle: FileHandle?
    private var terminalRelay: AgentTerminalRelay?
    private var humanControl = false
    private var humanControlStarted: TimeInterval?
    private var activeSeconds: TimeInterval = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var promptHandledAtByte = -1

    /// Only the native user interaction controls call this; providers cannot type.
    @discardableResult
    func takeControl() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0, !cancelled else { return false }
        if !humanControl { humanControlStarted = ProcessInfo.processInfo.systemUptime }
        humanControl = true
        return true
    }

    func returnControl() {
        lock.lock(); defer { lock.unlock() }
        humanControl = false
        humanControlStarted = nil
        promptHandledAtByte = bytesRead
        lastTick = ProcessInfo.processInfo.systemUptime
    }

    func sendInput(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard humanControl, pid > 0, !cancelled, let inputHandle else {
            throw POSIXError(.ESRCH)
        }
        // Keep writes below PIPE_BUF, nonblocking, and reject oversized pastes.
        let data = Data(text.utf8)
        guard data.count <= 512 else { throw POSIXError(.E2BIG) }
        let count = data.withUnsafeBytes { Darwin.write(inputHandle.fileDescriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if data.contains(3) { terminalInterruptRequested = true }
    }

    var terminalSocketPath: String? {
        lock.lock(); defer { lock.unlock() }
        return pid > 0 ? terminalRelay?.socketPath : nil
    }

    func resizeTerminal(columns: UInt16, rows: UInt16) {
        lock.lock(); let relay = terminalRelay; lock.unlock()
        relay?.resize(columns: columns, rows: rows)
    }

    /// Raw terminal bytes never pass through a text field or a provider schema.
    private func writeTerminalInput(_ data: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0, !cancelled, let inputHandle else { return -1 }
        let count = data.withUnsafeBytes { Darwin.write(inputHandle.fileDescriptor, $0.baseAddress, $0.count) }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return 0 }
        if count > 0, data.prefix(count).contains(3) { terminalInterruptRequested = true }
        return count
    }

    /// Plain-text excerpts for the model/transcript. Ghostty receives the
    /// original bytes; this only removes display controls from the saved log.
    static func plainOutput(_ output: String) -> String {
        let stripped = output
            .replacingOccurrences(of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(stripped.unicodeScalars.count)
        for scalar in stripped.unicodeScalars {
            if scalar.value == 8 || scalar.value == 127 {
                if scalars.last != "\n", !scalars.isEmpty { scalars.removeLast() }
            } else if scalar == "\r" {
                scalars.append("\n")
            } else if scalar == "\n" || scalar == "\t" || scalar.value >= 32 {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func plainPrompt(_ output: String) -> String {
        plainOutput(String(output.suffix(2048)))
    }

    static func looksLikePrompt(_ output: String) -> Bool {
        // A full-screen application owns the terminal until it exits. Hand it
        // over immediately rather than trying to classify its screen contents.
        if let entered = output.range(of: "\u{1b}[?1049h", options: .backwards),
           output.range(of: "\u{1b}[?1049l", range: entered.upperBound..<output.endIndex) == nil { return true }
        let tail = plainPrompt(output).trimmingCharacters(in: .whitespacesAndNewlines)
        let line = String(tail.split(whereSeparator: { $0.isNewline }).last ?? "")
        let patterns = [
            #"(?i)(\[[yn]/[yn]\]|\([yn]/[yn]\)|\[yes/no\]|password:|passphrase[^\n]*:|press (?:return|enter|any key)[^\n]*|(?:proceed|continue)[^\n]*\?)\s*[:?]?\s*$"#,
            #"(?i)\b(?:enter|choose|select|type|pick|input|confirm|provide)\b[^\n]*[:?>]\s*$"#,
            #"(?i)\b(?:do you|would you|are you|is this|should|which|what)\b[^\n]*\?\s*(?:\[[^\]]*\])?\s*$"#,
            #"(?i)(?:\[[^\]]*(?:/|default|[0-9]-[0-9])[^\]]*\]|\((?:yes/no|y/n)[^)]*\))\s*[:?>]?\s*$"#
        ]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    /// An unfamiliar unfinished prompt gets a bounded quiet period. A complete
    /// log line, progress percentage or ordinary silent job does not take focus.
    static func looksLikeSettledPrompt(_ output: String) -> Bool {
        let plain = plainPrompt(output)
        guard !plain.hasSuffix("\n"), !plain.hasSuffix("\r") else { return false }
        let line = String(plain.split(whereSeparator: { $0.isNewline }).last ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count < 300 else { return false }
        return line.hasSuffix(":") || line.hasSuffix("?") || line.hasSuffix(">")
    }

    /// script creates a separate terminal session. Stop its descendants as well
    /// as the launcher group, including children that hold the output pipe open.
    private func killTree(_ process: pid_t) {
        let size = proc_listchildpids(process, nil, 0)
        if size > 0 {
            var children = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
            let capacity = Int32(children.count * MemoryLayout<pid_t>.size)
            let read = children.withUnsafeMutableBytes { proc_listchildpids(process, $0.baseAddress, capacity) }
            for child in children.prefix(max(0, Int(read)) / MemoryLayout<pid_t>.size) where child > 0 {
                killTree(child)
            }
        }
        kill(-process, SIGKILL)
        kill(process, SIGKILL)
    }

    private func tick(timeout: TimeInterval) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        if !humanControl, bytesRead != promptHandledAtByte,
           let lastOutputAt, Date().timeIntervalSince(lastOutputAt) >= 1.5,
           Self.looksLikeSettledPrompt(String(decoding: capturedOutput, as: UTF8.self)) {
            humanControl = true
            humanControlStarted = now
        }
        if !humanControl { activeSeconds += now - lastTick }
        lastTick = now
        let expired = activeSeconds >= timeout || humanControlStarted.map { now - $0 >= 600 } == true
        lock.unlock()
        if expired { cancel() }
    }

    func snapshot() -> AgentProcessSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt else { return nil }
        return AgentProcessSnapshot(id: handleID, startedAt: startedAt, observedAt: Date(),
            lastOutputAt: lastOutputAt, bytesRead: bytesRead,
            output: Self.plainOutput(String(decoding: capturedOutput, as: UTF8.self)), truncated: outputTruncated, running: pid > 0, awaitingInput: humanControl)
    }

    init(searchPath: String = LoginShellPath.value) {
        self.searchPath = searchPath
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if pid > 0 {
            interrupted = true
            killTree(pid)
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
        let relay = try AgentTerminalRelay { [weak self] in self?.writeTerminalInput($0) ?? -1 }
        defer { relay.close() }
        let pipe = Pipe()
        let input = Pipe()
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
        }
        let inputFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inputFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, input.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, input.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        // GUI/test hosts can ignore or block SIGINT. An independent terminal
        // must restore normal child signal behavior so Control-C reaches it.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["/usr/bin/script", "-q", "/dev/null", "/bin/sh", "-c",
                         "stty echo onlcr cols 100 rows 24 || exit; /usr/bin/tty > \"$SORA_AGENT_TTY_PATH\"; unset SORA_AGENT_TTY_PATH; exec \"$@\"", "sora-agent", "/bin/zsh", "-f", "-o", "pipefail", "-c", command].map { value in value.withCString { strdup($0) } }
        var values = ProcessInfo.processInfo.environment
        values["PATH"] = searchPath
        values["ZDOTDIR"] = "/dev/null"
        values["TERM"] = "xterm-256color"
        values["SORA_AGENT_TTY_PATH"] = relay.ttyPathFile
        let environment = values.map { pair in "\(pair.key)=\(pair.value)".withCString { strdup($0) } }
        defer { (arguments + environment).forEach { free($0) } }
        var argv = arguments + [nil]
        var envp = environment + [nil]
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        var child: pid_t = 0
        let error = posix_spawn(&child, "/usr/bin/script", &actions, &attributes, &argv, &envp)
        if error == 0 {
            pid = child
            startedAt = Date()
            inputHandle = input.fileHandleForWriting
            terminalRelay = relay
            lastTick = ProcessInfo.processInfo.systemUptime
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
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now(), repeating: .milliseconds(100))
        deadline.setEventHandler { [weak self] in self?.tick(timeout: timeout) }
        deadline.resume()
        var output = Data()
        var truncated = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            relay.append(chunk)
            let room = max(0, outputLimit - output.count)
            output.append(chunk.prefix(room))
            if chunk.count > room { truncated = true }
            lock.lock()
            bytesRead += chunk.count
            lastOutputAt = Date()
            capturedOutput.append(chunk)
            if capturedOutput.count > outputLimit { capturedOutput.removeFirst(capturedOutput.count - outputLimit) }
            outputTruncated = truncated
            if bytesRead != promptHandledAtByte,
               Self.looksLikePrompt(String(decoding: capturedOutput, as: UTF8.self)) {
                if !humanControl { humanControlStarted = ProcessInfo.processInfo.systemUptime }
                humanControl = true
            }
            lock.unlock()
        }
        pipe.fileHandleForReading.closeFile()
        // WNOWAIT retains the PID until cancellation can no longer target it.
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        lock.lock()
        pid = 0
        inputHandle = nil
        humanControl = false
        let userInterrupted = terminalInterruptRequested
        let wasInterrupted = interrupted || userInterrupted
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        lock.unlock()
        deadline.cancel()
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return AgentCommandResult(command: command, directory: directory.path,
                                  output: Self.plainOutput(String(decoding: output, as: UTF8.self)), exitCode: code,
                                  interrupted: wasInterrupted, truncated: truncated, userInterrupted: userInterrupted)
    }
}
