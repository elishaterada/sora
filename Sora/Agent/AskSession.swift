import Combine
import Foundation

@MainActor
final class AskSession: ObservableObject {
    @Published var draft = ""
    @Published private(set) var webpage: WebpageAttachment?
    @Published private(set) var selectedProvider: AIBackendID
    @Published var model: String {
        didSet { defaults.set(model, forKey: "ai.model.\(selectedProvider.rawValue)") }
    }
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "ai.enabled")
            if !enabled { stop() }
        }
    }
    @Published private(set) var messages: [AIMessage] = []
    @Published private(set) var isSending = false
    @Published private(set) var isRunningCommand = false
    @Published private(set) var agentDirectory: URL?
    private var commandRunner: AgentCommandRunner?
    private var commandTask: Task<Void, Never>?
    private var commandGeneration: UUID?
    private var commandCount = 0
    private var runningMessageID: UUID?

    func configureAgent(directory: URL?) {
        guard !isSending, !isRunningCommand else { return }
        agentDirectory = directory
    }
    @Published private(set) var isUpdatingKey = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var setupMessage: String?

    private let backends: [AIBackendID: AIBackend]
    var availableProviders: [AIBackendID] { AIBackendID.allCases.filter { backends[$0] != nil } }
    private var provider: any AIProvider { backends[selectedProvider]!.provider }
    private var credentials: any AICredentialStore { backends[selectedProvider]!.credentials }
    private var conversations: any AIConversationStore { backends[selectedProvider]!.conversations }
    private var drafts: [AIBackendID: String] = [:]
    private var webpages: [AIBackendID: WebpageAttachment] = [:]
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var loaded = false
    private var loadFailed = false

    convenience init(provider: any AIProvider, credentials: any AICredentialStore,
                     conversations: any AIConversationStore, defaults: UserDefaults = .standard) {
        self.init(backends: [AIBackend(id: .openai, provider: provider, credentials: credentials,
                                     conversations: conversations)], defaults: defaults)
    }

    init(backends: [AIBackend], defaults: UserDefaults = .standard) {
        precondition(!backends.isEmpty)
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) })
        self.defaults = defaults
        let saved = AIBackendID(rawValue: defaults.string(forKey: "ai.provider") ?? "openai")
        let selected = backends.first(where: { $0.id == saved })?.id ?? backends[0].id
        self.selectedProvider = selected
        self.enabled = defaults.bool(forKey: "ai.enabled")
        let legacy = selected == .openai ? defaults.string(forKey: "ai.model") : nil
        self.model = defaults.string(forKey: "ai.model.\(selected.rawValue)") ?? legacy ?? selected.defaultModel
    }

    func selectProvider(_ id: AIBackendID) {
        guard id != selectedProvider, backends[id] != nil else { return }
        stop()
        drafts[selectedProvider] = draft
        webpages[selectedProvider] = webpage
        selectedProvider = id
        defaults.set(id.rawValue, forKey: "ai.provider")
        model = defaults.string(forKey: "ai.model.\(id.rawValue)")
            ?? (id == .openai ? defaults.string(forKey: "ai.model") : nil) ?? id.defaultModel
        draft = drafts[id] ?? ""
        webpage = webpages[id]
        messages = []
        loaded = false
        loadFailed = false
        errorMessage = nil
        setupMessage = nil
        load()
    }

    deinit { task?.cancel(); commandTask?.cancel(); commandRunner?.cancel() }

    var canSend: Bool {
        enabled && !isSending && !isRunningCommand && !isUpdatingKey && !loadFailed && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    func saveKey(_ key: String) async -> Bool {
        guard selectedProvider.needsKey, !isUpdatingKey, !isSending else { return false }
        let id = selectedProvider
        isUpdatingKey = true
        defer { isUpdatingKey = false }
        do {
            try await credentials.save(key)
            guard selectedProvider == id else { return false }
            setupMessage = "API key saved in Keychain."
            errorMessage = nil
            return true
        } catch {
            guard selectedProvider == id else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func attachWebpage(_ page: WebpageAttachment?) {
        guard !isSending else { return }
        webpage = page
    }

    func removeKey() async {
        guard selectedProvider.needsKey, !isUpdatingKey else { return }
        let id = selectedProvider
        isUpdatingKey = true
        defer { isUpdatingKey = false }
        stop()
        do {
            try await credentials.delete()
            guard selectedProvider == id else { return }
            setupMessage = "API key removed."
        } catch {
            if selectedProvider == id { errorMessage = error.localizedDescription }
        }
    }

    func send() {
        guard !isSending, !isRunningCommand else { return }
        commandCount = 0
        send(continuation: nil)
    }

    private func send(continuation: String?) {
        load()
        guard !isSending, !isRunningCommand, !isUpdatingKey else { return }
        guard enabled else { errorMessage = AIError.disabled.localizedDescription; return }
        guard !loadFailed else { return }
        let question = (continuation ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedProvider.needsKey || !model.isEmpty else { errorMessage = AIError.invalidModel.localizedDescription; return }

        do {
            // Send only complete question/answer pairs. Stopped or failed turns
            // stay visible locally but cannot masquerade as complete answers.
            var context: [AIMessage] = []
            for index in messages.indices where messages[index].role == .assistant && messages[index].status == .complete {
                guard index > 0, messages[index - 1].role == .user else { continue }
                context.append(contentsOf: [messages[index - 1], messages[index]])
            }
            let user = AIMessage(role: .user, text: question, webpage: continuation == nil ? webpage : nil, isAgentContinuation: continuation != nil)
            context.append(user)
            guard try context.reduce(0, { $0 + (try $1.contentForProvider()).utf8.count }) <= 100_000 else {
                throw AIError.contextTooLarge
            }
            let response = AIMessage(role: .assistant, text: "", status: .streaming, commandDirectory: agentDirectory?.path)
            let updated = messages + [user, response]
            try conversations.save(updated)
            messages = updated
            if continuation == nil {
                draft = ""
                webpage = nil
                webpages[selectedProvider] = nil
            }
            errorMessage = nil
            isSending = true
            let token = UUID()
            generation = token
            if let agentDirectory {
                context[context.count - 1].text += "\n\nAgent working directory: " + agentDirectory.path
            }
            let request = AIRequest(model: model, messages: context)
            let provider = provider
            let credentials = credentials
            let needsKey = selectedProvider.needsKey
            task = Task { [weak self] in
                do {
                    let key: String
                    if needsKey {
                        guard let savedKey = try await credentials.read(), !savedKey.isEmpty else {
                            throw AIError.missingKey
                        }
                        key = savedKey
                    } else { key = "" }
                    try Task.checkCancellation()
                    guard self?.generation == token else { return }
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
        if let id = runningMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].commandState = "stopped"
            persist()
        }
        runningMessageID = nil
        commandGeneration = nil
        commandRunner?.cancel()
        commandRunner = nil
        commandTask?.cancel()
        commandTask = nil
        isRunningCommand = false
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
            webpage = nil
            webpages[selectedProvider] = nil
            loadFailed = false
            loaded = true
            errorMessage = nil
        } catch { errorMessage = "The conversation could not be cleared: \(error.localizedDescription)" }
    }

    func approveCommand(messageID: UUID) -> AgentCommandProposal? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].commandProposal,
              proposal.status == .pending
        else { return nil }
        proposal.status = .approved
        var updated = messages
        updated[index].commandProposal = proposal
        do {
            try conversations.save(updated)
            messages = updated
            errorMessage = nil
            return proposal
        } catch {
            errorMessage = "The approval could not be saved, so the command was not run: \(error.localizedDescription)"
            return nil
        }
    }

    func dismissCommand(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].commandProposal,
              proposal.status == .pending
        else { return }
        proposal.status = .dismissed
        var updated = messages
        updated[index].commandProposal = proposal
        do {
            try conversations.save(updated)
            messages = updated
            errorMessage = nil
        } catch {
            errorMessage = "The command decision could not be saved: \(error.localizedDescription)"
        }
    }

    func reportCommandUnavailable() {
        errorMessage = "Return to an empty, ready shell prompt before running this command."
    }

    private func finish(token: UUID, responseID: UUID, status: AIMessage.Status, error: String? = nil) {
        guard generation == token else { return }
        generation = nil
        task = nil
        isSending = false
        if let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].status = status
            if status == .complete,
               let proposal = AgentCommandProposalParser.parse(messages[index].text) {
                messages[index].text = proposal.summary
                messages[index].commandProposal = proposal
            }
        }
        errorMessage = error
        persist()
        if status == .complete, errorMessage == nil, agentDirectory != nil,
           let proposal = messages.first(where: { $0.id == responseID })?.commandProposal,
           AgentCommandPermission.allowsAutomatically(proposal.command) {
            runCommand(messageID: responseID)
        }
    }

    func runCommand(messageID: UUID) {
        guard enabled, !isSending, !isRunningCommand,
              let message = messages.first(where: { $0.id == messageID }),
              let path = message.commandDirectory ?? agentDirectory?.path else { return }
        let directory = URL(fileURLWithPath: path)
        agentDirectory = directory
        guard commandCount < 6 else {
            errorMessage = "Paused after six commands. Send a follow-up to continue."
            return
        }
        guard let proposal = approveCommand(messageID: messageID) else { return }
        commandCount += 1
        let runner = AgentCommandRunner()
        let token = UUID()
        commandRunner = runner
        commandGeneration = token
        isRunningCommand = true
        runningMessageID = messageID
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].commandState = "running"
        }
        commandTask = Task { [weak self] in
            do {
                let result = try await runner.run(command: proposal.command, directory: directory)
                guard let self, self.commandGeneration == token else { return }
                self.isRunningCommand = false
                self.commandRunner = nil
                self.commandTask = nil
                self.commandGeneration = nil
                guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                self.messages[index].commandResult = result
                self.messages[index].commandState = result.interrupted ? "stopped" : "finished"
                self.runningMessageID = nil
                self.persist()
                guard self.errorMessage == nil else { return }
                if result.interrupted {
                    self.errorMessage = "Command stopped after reaching its time limit. Send a follow-up to continue."
                } else {
                    self.send(continuation: "Review the command result, continue the original task if needed, and summarize findings with a useful next step when done.")
                }
            } catch {
                guard let self, self.commandGeneration == token else { return }
                self.isRunningCommand = false
                self.commandRunner = nil
                self.commandTask = nil
                self.commandGeneration = nil
                if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[index].commandState = "failed"
                }
                self.runningMessageID = nil
                self.persist()
                self.errorMessage = "Command could not run: \(error.localizedDescription)"
            }
        }
    }

    private func persist() {
        do { try conversations.save(messages) }
        catch { errorMessage = "The conversation could not be saved: \(error.localizedDescription)" }
    }
}
