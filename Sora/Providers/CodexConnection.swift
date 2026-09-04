import Foundation

enum CodexError: LocalizedError {
    case notInstalled, disconnected, requestFailed, timedOut, notSignedIn, incompatible
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Install the current Codex CLI or Codex desktop app, then try again."
        case .disconnected: return "The Codex connection closed. Try again."
        case .requestFailed: return "Codex rejected the request. Check your sign-in and model, or update Codex."
        case .timedOut: return "Codex did not respond in time. Try again."
        case .notSignedIn: return "Sign in to Codex in Setup first."
        case .incompatible: return "This Codex version does not support Sora's text-only Ask configuration. Update Codex."
        }
    }
}

/// One local stdio app-server per request/login. No token files are read by Sora.
/// Mutable transport state is protected by lock; stdout is drained off the UI.
final class CodexConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 0
    private var closed = false
    private var running = false
    private let receive: @Sendable ([String: Any]) -> Void
    private let ended: @Sendable (Error) -> Void

    init(receive: @escaping @Sendable ([String: Any]) -> Void = { _ in },
         ended: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.receive = receive
        self.ended = ended
    }

    static func executable() -> URL? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    static var arguments: [String] {
        let disabled = ["shell_tool", "unified_exec", "hooks", "plugins", "apps", "multi_agent",
                        "memories", "browser_use", "skill_search", "skill_mcp_dependency_install", "tool_suggest"]
        let settings = disabled.map { "features.\($0)=false" } + [
            "features.skip_host_skill_discovery=true", "mcp_servers={}", "web_search=\"disabled\"",
            "tools.view_image=false", "project_doc_max_bytes=0", "cli_auth_credentials_store=\"keyring\"",
            "model_provider=\"openai\"", "approval_policy=\"on-request\"", "approvals_reviewer=\"user\""
        ]
        return ["app-server", "--listen", "stdio://"] + settings.flatMap { ["-c", $0] }
    }

    func start(executable: URL? = nil) async throws {
        guard let executable = executable ?? Self.executable() else { throw CodexError.notInstalled }
        try launch(executable)
        let initialized = try await rpc("initialize", [
            "clientInfo": ["name": "sora", "title": "Sora", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ])
        guard let agent = initialized["userAgent"] as? String, Self.supports(agent) else {
            close(CodexError.incompatible)
            throw CodexError.incompatible
        }
        try notify("initialized", [:])
    }

    static func supports(_ userAgent: String) -> Bool {
        let version = userAgent.split(separator: "/").dropFirst().first?
            .split(separator: " ").first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard version.count == 3 else { return false }
        return version[0] > 0 || version[1] >= 153
    }

    private func launch(_ executable: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        process.executableURL = executable
        process.arguments = Self.arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        // Never print app-server diagnostics that may contain local paths or auth data.
        process.standardError = FileHandle.nullDevice
        try process.run()
        running = true
        DispatchQueue(label: "dev.sora.codex.read").async { [self] in
            var buffer = Data()
            do {
                // read(upToCount:) can wait to fill its buffer on a pipe. JSON-RPC
                // replies are short and the server keeps stdout open between them.
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }
                    buffer.append(chunk)
                    guard buffer.count <= 4_000_000 else { throw AIError.malformedResponse }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        guard !line.isEmpty else { continue }
                        guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                            throw AIError.malformedResponse
                        }
                        handle(object)
                    }
                }
                close(CodexError.disconnected)
            } catch { close(error) }
        }
    }

    func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !closed else { lock.unlock(); continuation.resume(throwing: CodexError.disconnected); return }
                nextID += 1
                let id = nextID
                pending[id] = continuation
                do { try writeLocked(["id": id, "method": method, "params": params]) }
                catch {
                    pending.removeValue(forKey: id)
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 45) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let waiting = self.pending[id] != nil
                    self.lock.unlock()
                    if waiting { self.close(CodexError.timedOut) }
                }
            }
        } onCancel: { self.close(CancellationError()) }
    }

    func notify(_ method: String, _ params: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CodexError.disconnected }
        try writeLocked(["method": method, "params": params])
    }

    private func writeLocked(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"], object["method"] != nil {
            // This slice cannot grant any server-originated tool permission.
            lock.lock()
            try? writeLocked(["id": id, "error": ["code": -32601, "message": "Sora Ask does not provide tools or approvals."]])
            lock.unlock()
            return
        }
        if let id = object["id"] as? Int {
            lock.lock()
            let continuation = pending.removeValue(forKey: id)
            lock.unlock()
            if object["error"] != nil { continuation?.resume(throwing: CodexError.requestFailed) }
            else if let result = object["result"] as? [String: Any] { continuation?.resume(returning: result) }
            else { continuation?.resume(throwing: AIError.malformedResponse) }
        } else { receive(object) }
    }

    func close(_ error: Error = CancellationError()) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let waiting = Array(pending.values)
        pending.removeAll()
        if running && process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        lock.unlock()
        waiting.forEach { $0.resume(throwing: error) }
        ended(error)
    }
}
