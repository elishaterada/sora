import Combine
import Foundation

@MainActor
final class AskSession: ObservableObject {
    @Published var draft = ""
    @Published var model: String {
        didSet { defaults.set(model, forKey: "ai.model") }
    }
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "ai.enabled")
            if !enabled { stop() }
        }
    }
    @Published private(set) var messages: [AIMessage] = []
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var setupMessage: String?

    private let provider: any AIProvider
    private let credentials: any AICredentialStore
    private let conversations: any AIConversationStore
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var loaded = false
    private var loadFailed = false

    init(provider: any AIProvider, credentials: any AICredentialStore,
         conversations: any AIConversationStore, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.credentials = credentials
        self.conversations = conversations
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: "ai.enabled")
        self.model = defaults.string(forKey: "ai.model") ?? "gpt-5.4-mini"
    }

    deinit { task?.cancel() }

    var canSend: Bool {
        enabled && !isSending && !loadFailed && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        do { messages = try conversations.load() }
        catch {
            loadFailed = true
            errorMessage = "The saved conversation could not be opened. Start a new conversation to replace it."
        }
    }

    func saveKey(_ key: String) -> Bool {
        do {
            try credentials.save(key)
            setupMessage = "API key saved in Keychain."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeKey() {
        stop()
        do {
            try credentials.delete()
            setupMessage = "API key removed."
        } catch { errorMessage = error.localizedDescription }
    }

    func send() {
        load()
        guard !isSending else { return }
        guard enabled else { errorMessage = AIError.disabled.localizedDescription; return }
        guard !loadFailed else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { errorMessage = AIError.invalidModel.localizedDescription; return }

        do {
            guard let key = try credentials.read(), !key.isEmpty else { throw AIError.missingKey }
            // Send only complete question/answer pairs. Stopped or failed turns
            // stay visible locally but cannot masquerade as complete answers.
            var context: [AIMessage] = []
            for index in messages.indices where messages[index].role == .assistant && messages[index].status == .complete {
                guard index > 0, messages[index - 1].role == .user else { continue }
                context.append(contentsOf: [messages[index - 1], messages[index]])
            }
            let user = AIMessage(role: .user, text: question)
            context.append(user)
            guard context.reduce(0, { $0 + $1.text.utf8.count }) <= 100_000 else { throw AIError.contextTooLarge }
            let response = AIMessage(role: .assistant, text: "", status: .streaming)
            let updated = messages + [user, response]
            try conversations.save(updated)
            messages = updated
            draft = ""
            errorMessage = nil
            isSending = true
            let token = UUID()
            generation = token
            let request = AIRequest(model: model, messages: context)
            let provider = provider
            task = Task { [weak self] in
                do {
                    var completed = false
                    for try await event in provider.events(for: request, credential: key) {
                        try Task.checkCancellation()
                        guard let self, self.generation == token else { return }
                        switch event {
                        case .text(let text):
                            guard let index = self.messages.firstIndex(where: { $0.id == response.id }) else { return }
                            self.messages[index].text += text
                        case .completed: completed = true
                        }
                    }
                    try Task.checkCancellation()
                    guard completed else { throw AIError.incompleteStream }
                    guard let text = self?.messages.first(where: { $0.id == response.id })?.text,
                          !text.isEmpty else { throw AIError.responseFailed }
                    self?.finish(token: token, responseID: response.id, status: .complete)
                } catch {
                    guard let self, self.generation == token else { return }
                    let stopped = Task.isCancelled || error is CancellationError
                    self.finish(token: token, responseID: response.id, status: stopped ? .stopped : .failed,
                                error: stopped ? nil : error.localizedDescription)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() {
        generation = nil
        task?.cancel()
        task = nil
        guard isSending else { return }
        isSending = false
        if let index = messages.lastIndex(where: { $0.status == .streaming }) {
            messages[index].status = .stopped
        }
        persist()
    }

    func newConversation() {
        stop()
        do {
            try conversations.save([])
            messages = []
            loadFailed = false
            loaded = true
            errorMessage = nil
        } catch { errorMessage = "The conversation could not be cleared: \(error.localizedDescription)" }
    }

    private func finish(token: UUID, responseID: UUID, status: AIMessage.Status, error: String? = nil) {
        guard generation == token else { return }
        generation = nil
        task = nil
        isSending = false
        if let index = messages.firstIndex(where: { $0.id == responseID }) { messages[index].status = status }
        errorMessage = error
        persist()
    }

    private func persist() {
        do { try conversations.save(messages) }
        catch { errorMessage = "The conversation could not be saved: \(error.localizedDescription)" }
    }
}
