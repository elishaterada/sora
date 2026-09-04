import AppKit
import Combine

@MainActor
final class CodexLogin: ObservableObject {
    @Published private(set) var status = "Use your Codex sign-in, or sign in with ChatGPT."
    @Published private(set) var isBusy = false
    private var connection: CodexConnection?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func connect(signIn: Bool) {
        cancel()
        let token = UUID()
        generation = token
        isBusy = true
        status = signIn ? "Opening Codex sign-in…" : "Checking Codex…"
        let connection = CodexConnection(receive: { [weak self] object in
            guard object["method"] as? String == "account/login/completed",
                  let params = object["params"] as? [String: Any] else { return }
            let success = params["success"] as? Bool == true
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.status = success ? "Signed in to Codex." : "Codex sign-in was not completed. Try again."
                self.cancel()
            }
        }, ended: { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.status = error.localizedDescription
                self.cancel()
            }
        })
        self.connection = connection
        task = Task { [weak self] in
            do {
                try await connection.start()
                if signIn {
                    let result = try await connection.rpc("account/login/start", ["type": "chatgpt"])
                    guard let raw = result["authUrl"] as? String, let url = URL(string: raw),
                          url.scheme == "https", url.host == "auth.openai.com" else { throw AIError.malformedResponse }
                    guard let self, self.generation == token else { return }
                    guard NSWorkspace.shared.open(url) else { throw CodexError.requestFailed }
                    self.status = "Finish signing in in your browser."
                } else {
                    let result = try await connection.rpc("account/read", ["refreshToken": false])
                    guard let self, self.generation == token else { return }
                    self.status = result["account"] is [String: Any] ? "Codex is signed in and ready." : "No Codex Keychain sign-in found. Choose Sign In."
                    self.cancel()
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.status = error.localizedDescription
                self.cancel()
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        connection?.close()
        connection = nil
        isBusy = false
    }
}
