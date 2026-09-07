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
    @Published var realtimeVoiceModel: String {
        didSet { defaults.set(realtimeVoiceModel, forKey: "ai.voice.realtimeModel") }
    }
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "ai.enabled")
            if !enabled { stop() }
        }
    }
    @Published var permissionMode: AgentPermissionMode {
        didSet { defaults.set(permissionMode.rawValue, forKey: AgentPermissionMode.defaultsKey) }
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
    /// Set by Stop; completion stores any output and must not continue the agent loop.
    private var commandStopRequested = false
    /// Tab-scoped transcripts. Keys are `tabID.provider`.
    private var transcripts: [String: [AIMessage]] = [:]
    private(set) var activeTabID: UUID?
    /// Used before the workspace binds a real tab (tests and early Setup).
    private let unboundTabID = UUID()

    private var transcriptTabID: UUID { activeTabID ?? unboundTabID }

    func configureAgent(directory: URL?) {
        guard !isSending, !isRunningCommand else { return }
        agentDirectory = directory
    }

    /// Isolate Ask history per terminal tab. Switching tabs never shows another
    /// tab's agent thread.
    func bindTab(_ id: UUID) {
        if activeTabID == id {
            if !loaded { load() }
            return
        }
        finalizeRealtimeVoiceMessages()
        stashCurrentTranscript()
        stop()
        activeTabID = id
        messages = transcripts[transcriptKey(tab: id, provider: selectedProvider)] ?? []
        loaded = true
        loadFailed = false
        commandCount = 0
        errorMessage = nil
    }

    func discardTab(_ id: UUID) {
        for provider in AIBackendID.allCases {
            transcripts.removeValue(forKey: transcriptKey(tab: id, provider: provider))
        }
        guard activeTabID == id else { return }
        stop()
        activeTabID = nil
        messages = transcripts[transcriptKey(tab: unboundTabID, provider: selectedProvider)] ?? []
        loaded = true
    }

    /// Terminal → agent routing always starts a fresh thread for the active tab.
    func beginTerminalAgent(question: String, directory: URL?) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        messages = []
        transcripts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = []
        webpage = nil
        webpages[selectedProvider] = nil
        draft = trimmed
        agentDirectory = directory
        commandCount = 0
        errorMessage = nil
        loaded = true
        loadFailed = false
        send()
    }

    private func transcriptKey(tab: UUID, provider: AIBackendID) -> String {
        "\(tab.uuidString).\(provider.rawValue)"
    }

    private func stashCurrentTranscript() {
        transcripts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = messages
    }

    /// Visible when the user returns to the terminal after an agent turn.
    var resumeSummary: AgentResumeSummary? {
        let users = messages.filter { $0.role == .user && $0.isAgentContinuation != true }
        guard let first = users.first else { return nil }
        let followUp: String?
        if isRunningCommand {
            followUp = "Running…"
        } else if isSending {
            followUp = "Answering…"
        } else if users.count > 1, let last = users.last?.text, last != first.text {
            followUp = last
        } else {
            followUp = nil
        }
        return AgentResumeSummary(
            title: AgentResumeSummary.title(from: first.text),
            latestFollowUp: followUp
        )
    }

    @Published private(set) var isUpdatingKey = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var setupMessage: String?

    private let backends: [AIBackendID: AIBackend]
    var availableProviders: [AIBackendID] { AIBackendID.allCases.filter { backends[$0] != nil } }
    private var provider: any AIProvider { backends[selectedProvider]!.provider }
    private var credentials: any AICredentialStore { backends[selectedProvider]!.credentials }
    private var conversations: any AIConversationStore { backends[selectedProvider]!.conversations }
    private let webpageFetcher: any WebpageFetching
    private var drafts: [AIBackendID: String] = [:]
    private var webpages: [AIBackendID: WebpageAttachment] = [:]
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var loaded = false
    private var loadFailed = false

    convenience init(provider: any AIProvider, credentials: any AICredentialStore,
                     conversations: any AIConversationStore, defaults: UserDefaults = .standard,
                     webpageFetcher: any WebpageFetching = WebpageFetcher()) {
        self.init(backends: [AIBackend(id: .openai, provider: provider, credentials: credentials,
                                     conversations: conversations)], defaults: defaults,
                  webpageFetcher: webpageFetcher)
    }

    init(backends: [AIBackend], defaults: UserDefaults = .standard,
         webpageFetcher: any WebpageFetching = WebpageFetcher()) {
        precondition(!backends.isEmpty)
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) })
        self.defaults = defaults
        self.webpageFetcher = webpageFetcher
        let saved = AIBackendID(rawValue: defaults.string(forKey: "ai.provider") ?? "openai")
        let selected = backends.first(where: { $0.id == saved })?.id ?? backends[0].id
        self.selectedProvider = selected
        self.enabled = defaults.bool(forKey: "ai.enabled")
        self.permissionMode = AgentPermissionMode.stored(in: defaults)
        let legacy = selected == .openai ? defaults.string(forKey: "ai.model") : nil
        self.model = defaults.string(forKey: "ai.model.\(selected.rawValue)") ?? legacy ?? selected.defaultModel
        self.realtimeVoiceModel = defaults.string(forKey: "ai.voice.realtimeModel")
            ?? RealtimeVoiceModel.recommended
    }

    func selectProvider(_ id: AIBackendID) {
        guard id != selectedProvider, backends[id] != nil else { return }
        stop()
        finalizeRealtimeVoiceMessages()
        stashCurrentTranscript()
        drafts[selectedProvider] = draft
        webpages[selectedProvider] = webpage
        selectedProvider = id
        defaults.set(id.rawValue, forKey: "ai.provider")
        model = defaults.string(forKey: "ai.model.\(id.rawValue)")
            ?? (id == .openai ? defaults.string(forKey: "ai.model") : nil) ?? id.defaultModel
        draft = drafts[id] ?? ""
        webpage = webpages[id]
        messages = transcripts[transcriptKey(tab: transcriptTabID, provider: id)] ?? []
        loaded = true
        loadFailed = false
        errorMessage = nil
        setupMessage = nil
    }

    deinit { task?.cancel(); commandTask?.cancel(); commandRunner?.cancel() }

    var canSend: Bool {
        enabled && !isSending && !isRunningCommand && !isUpdatingKey && !loadFailed && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var realtimeVoiceAvailability: RealtimeVoiceAvailability {
        guard enabled else {
            return .unavailable("Enable Agent in Settings to use realtime voice.")
        }
        guard selectedProvider == .openai else {
            return .unavailable("Realtime voice currently requires the OpenAI API service.")
        }
        guard RealtimeVoiceModel.isSupported(realtimeVoiceModel) else {
            return .unavailable("Choose a supported realtime model in Voice Settings.")
        }
        return .available
    }

    func realtimeVoiceCredential() async throws -> String {
        guard realtimeVoiceAvailability.isAvailable else {
            throw RealtimeVoiceError.unavailable(realtimeVoiceAvailability.reason ?? "Realtime voice is unavailable.")
        }
        guard let key = try await credentials.read(), !key.isEmpty else { throw AIError.missingKey }
        return key
    }

    func beginRealtimeVoiceMessage(role: AIMessage.Role) -> UUID {
        load()
        let message = AIMessage(role: role, text: "", status: .streaming, isVoiceInput: true)
        messages.append(message)
        stashCurrentTranscript()
        return message.id
    }

    func updateRealtimeVoiceMessage(id: UUID, text: String, completed: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        messages[index].status = completed ? .complete : .streaming
        if completed {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.remove(at: index)
            }
            persist()
        } else {
            stashCurrentTranscript()
        }
    }

    func stopRealtimeVoiceMessage(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].status == .streaming else { return }
        if messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        } else {
            messages[index].status = .stopped
        }
        persist()
    }

    private func finalizeRealtimeVoiceMessages() {
        messages.removeAll {
            $0.isVoiceInput == true && $0.status == .streaming
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for index in messages.indices where messages[index].isVoiceInput == true
            && messages[index].status == .streaming {
            messages[index].status = .stopped
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        // Agent threads are tab-scoped in memory. Do not hydrate a shared
        // cross-tab transcript from disk into the active pane.
        messages = transcripts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] ?? []
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
                    var currentRequest = request
                    for attempt in 0...2 {
                        var completed = false
                        for try await event in provider.events(for: currentRequest, credential: key) {
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
                        guard let self, self.generation == token,
                              let index = self.messages.firstIndex(where: { $0.id == response.id }) else { return }
                        let text = self.messages[index].text
                        guard !text.isEmpty else { throw AIError.responseFailed }
                        guard AgentEnvelope.needsRepair(text), attempt < 2 else { break }
                        // Retry generation only: no command/fetch has been proposed
                        // or executed. Reuse the original context, not failed turns.
                        var repairedContext = request.messages
                        repairedContext.append(AIMessage(role: .user, text: AgentEnvelope.repairInstruction))
                        guard try repairedContext.reduce(0, { $0 + (try $1.contentForProvider()).utf8.count }) <= 100_000 else {
                            throw AIError.contextTooLarge
                        }
                        currentRequest = AIRequest(model: request.model, messages: repairedContext)
                        self.messages[index].text = ""
                        self.errorMessage = nil
                    }
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
        // Kill the process group immediately, but keep isRunningCommand set until
        // the runner finishes so a second command cannot start over a dying one.
        if isRunningCommand || commandRunner != nil || commandTask != nil {
            commandStopRequested = true
            if let id = runningMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].commandState = "stopped"
                persist()
            }
            commandRunner?.cancel()
            commandTask?.cancel()
        }
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
        messages = []
        transcripts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = []
        do {
            try conversations.save([])
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
        var envelopeError: String?
        if let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].status = status
            if status == .complete {
                let text = messages[index].text
                if let match = AgentCommandProposalParser.match(text) {
                    messages[index].text = match.prose.isEmpty ? match.proposal.summary : match.prose
                    messages[index].commandProposal = match.proposal
                } else if let match = AgentWebpageProposalParser.match(text) {
                    messages[index].text = match.prose.isEmpty ? match.proposal.summary : match.prose
                    messages[index].webpageProposal = match.proposal
                } else if AgentEnvelope.needsRepair(text) {
                    // Never leave Sora's wire format in the transcript. Say what
                    // happened instead of silently dropping the request.
                    let prose = AgentCommandProposalParser.proseBeforeEnvelope(in: text)
                        ?? AgentWebpageProposalParser.proseBeforeEnvelope(in: text)
                        ?? ""
                    messages[index].text = prose
                    messages[index].status = .failed
                    envelopeError = "The assistant could not produce a valid action after two automatic retries. Nothing was run. Try rephrasing your request."
                }
            }
        }
        errorMessage = error ?? envelopeError
        persist()
        guard status == .complete, errorMessage == nil else { return }
        let message = messages.first(where: { $0.id == responseID })
        if agentDirectory != nil,
           let proposal = message?.commandProposal,
           AgentCommandPermission.shouldAutoRunCommand(proposal.command, mode: permissionMode) {
            runCommand(messageID: responseID)
        } else if message?.webpageProposal != nil,
                  AgentCommandPermission.shouldAutoFetchWebpage(mode: permissionMode) {
            fetchWebpage(messageID: responseID)
        }
    }

    func dismissWebpage(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].webpageProposal,
              proposal.status == .pending
        else { return }
        proposal.status = .dismissed
        messages[index].webpageProposal = proposal
        persist()
    }

    func fetchWebpage(messageID: UUID) {
        guard enabled, !isSending, !isRunningCommand,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].webpageProposal,
              proposal.status == .pending
        else { return }
        guard commandCount < 6 else {
            errorMessage = "Paused after six agent actions. Send a follow-up to continue."
            return
        }
        proposal.status = .approved
        messages[index].webpageProposal = proposal
        messages[index].commandState = "fetching"
        persist()
        commandCount += 1
        let token = UUID()
        commandGeneration = token
        commandStopRequested = false
        isRunningCommand = true
        runningMessageID = messageID
        let address = proposal.url
        let fetcher = webpageFetcher
        commandTask = Task { [weak self] in
            do {
                let page = try await fetcher.fetch(address)
                guard let self, self.commandGeneration == token else { return }
                let stoppedByUser = self.commandStopRequested
                if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[index].webpage = page
                    self.messages[index].commandState = stoppedByUser ? "stopped" : "finished"
                }
                self.finishAgentAction(token: token)
                guard self.errorMessage == nil, !stoppedByUser else { return }
                self.send(continuation: "Review the webpage snapshot, continue the original task if needed, and summarize findings with a useful next step when done.")
            } catch {
                guard let self, self.commandGeneration == token else { return }
                let stoppedByUser = self.commandStopRequested || error is CancellationError
                if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[index].webpageProposal?.status = .failed
                    self.messages[index].commandState = stoppedByUser ? "stopped" : "failed"
                }
                self.finishAgentAction(token: token)
                guard self.errorMessage == nil, !stoppedByUser else { return }
                self.send(continuation: "The webpage fetch failed (\(error.localizedDescription)). Continue with a different public HTTPS URL or answer without it.")
            }
        }
    }

    private func finishAgentAction(token: UUID) {
        guard commandGeneration == token else { return }
        commandStopRequested = false
        isRunningCommand = false
        commandRunner = nil
        commandTask = nil
        commandGeneration = nil
        runningMessageID = nil
        persist()
    }

    func runCommand(messageID: UUID) {
        guard enabled, !isSending, !isRunningCommand,
              let message = messages.first(where: { $0.id == messageID }),
              let path = message.commandDirectory ?? agentDirectory?.path else { return }
        let directory = URL(fileURLWithPath: path)
        agentDirectory = directory
        guard commandCount < 6 else {
            errorMessage = "Paused after six agent actions. Send a follow-up to continue."
            return
        }
        guard let proposal = approveCommand(messageID: messageID) else { return }
        commandCount += 1
        let runner = AgentCommandRunner()
        let token = UUID()
        commandRunner = runner
        commandGeneration = token
        commandStopRequested = false
        isRunningCommand = true
        runningMessageID = messageID
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].commandState = "running"
        }
        commandTask = Task { [weak self] in
            do {
                let result = try await runner.run(command: proposal.command, directory: directory)
                guard let self, self.commandGeneration == token else { return }
                let stoppedByUser = self.commandStopRequested
                self.finishCommand(token: token, messageID: messageID, result: result, error: nil)
                guard self.errorMessage == nil else { return }
                if stoppedByUser {
                    return
                }
                if result.interrupted {
                    self.errorMessage = "Command stopped after reaching its time limit. Send a follow-up to continue."
                } else {
                    self.send(continuation: "Review the command result, continue the original task if needed, and summarize findings with a useful next step when done.")
                }
            } catch {
                guard let self, self.commandGeneration == token else { return }
                let stoppedByUser = self.commandStopRequested || error is CancellationError
                let result = AgentCommandResult(
                    command: proposal.command,
                    directory: directory.path,
                    output: "",
                    exitCode: 137,
                    interrupted: true,
                    truncated: false
                )
                self.finishCommand(
                    token: token,
                    messageID: messageID,
                    result: stoppedByUser || error is CancellationError ? result : nil,
                    error: stoppedByUser ? nil : "Command could not run: \(error.localizedDescription)"
                )
            }
        }
    }

    private func finishCommand(token: UUID, messageID: UUID, result: AgentCommandResult?, error: String?) {
        guard commandGeneration == token else { return }
        let stoppedByUser = commandStopRequested
        commandStopRequested = false
        isRunningCommand = false
        commandRunner = nil
        commandTask = nil
        commandGeneration = nil
        runningMessageID = nil
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            if let result {
                messages[index].commandResult = result
                messages[index].commandState = (stoppedByUser || result.interrupted) ? "stopped" : "finished"
            } else if messages[index].commandState == "running" || messages[index].commandState == "stopped" {
                messages[index].commandState = error == nil ? "stopped" : "failed"
            }
            persist()
        }
        if let error { errorMessage = error }
    }

    private func persist() {
        stashCurrentTranscript()
        do { try conversations.save(messages) }
        catch { errorMessage = "The conversation could not be saved: \(error.localizedDescription)" }
    }
}
