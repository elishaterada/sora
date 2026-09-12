import AppKit
import Combine
import Foundation

@MainActor
final class AskSession: ObservableObject {
    weak var skinLibrary: SkinLibrary?
    /// Clip preparation keeps downloads and file changes reviewable even if the global mode is Full access.
    var requiresCommandApproval = false
    var commandPermissionMode: AgentPermissionMode { requiresCommandApproval && permissionMode == .fullAccess ? .approveForMe : permissionMode }
    @Published var draft = ""
    @Published private(set) var goal: AgentGoal?
    private var goals: [String: AgentGoal] = [:]
    private var answeringQuestion = false
    #if DEBUG
    var completionGateEnabled = true
    #endif
    private var usesCompletionGate: Bool {
        #if DEBUG
        return completionGateEnabled
        #else
        return true
        #endif
    }
    var commandTimeout: TimeInterval = 300
    private var processMonitor: Task<Void, Never>?
    var defaultBudget = AgentBudget()
    private var budgetWorkStarted: Date?
    private var budgetDeadline: Task<Void, Never>?
    @Published var pendingTerminalOutput: TerminalOutputAttachment?
    private var terminalOutputDrafts: [String: TerminalOutputAttachment] = [:]

    func attachTerminalOutput(_ attachment: TerminalOutputAttachment) {
        pendingTerminalOutput = attachment
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = "Explain this terminal output and identify any problem."
        }
    }

    @Published var pendingImages: [AIImageAttachment] = []
    private var imageDrafts: [String: [AIImageAttachment]] = [:]

    func attachImages(_ urls: [URL]) {
        do {
            guard pendingImages.count + urls.count <= 4 else { throw imageError("Attach up to four images at a time.") }
            let attachments = try urls.map { url -> AIImageAttachment in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20_000_000 else { throw imageError("Choose an image smaller than 20 MB.") }
                let data = try Data(contentsOf: url)
                guard let bitmap = NSBitmapImageRep(data: data),
                      bitmap.pixelsWide <= 8192, bitmap.pixelsHigh <= 8192,
                      let png = bitmap.representation(using: .png, properties: [:]), png.count <= 5_000_000 else {
                    throw imageError("Choose an image under 8192 pixels per side and 5 MB when converted to PNG.")
                }
                return AIImageAttachment(name: url.lastPathComponent, png: png)
            }
            pendingImages += attachments
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func imageError(_ message: String) -> NSError {
        NSError(domain: "Sora.Image", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @Published private(set) var programs: [AgentProgram] = []
    @Published private(set) var programError: String?
    private var programStore: AgentProgramStore
    private var sharedObservations = Set<AnyCancellable>()

    /// Preferences are app-wide; drafts, responses and cancellation belong to
    /// this window. Compare first so applying a notification cannot echo forever.
    func refreshSharedPreferences() {
        let storedEnabled = defaults.bool(forKey: "ai.enabled")
        if enabled != storedEnabled { enabled = storedEnabled }
        if !isSending, !isRunningCommand, let id = AIBackendID(rawValue: defaults.string(forKey: "ai.provider") ?? "openai"),
           id != selectedProvider { selectProvider(id) }
        let storedModel = defaults.string(forKey: "ai.model.\(selectedProvider.rawValue)")
            ?? (selectedProvider == .openai ? defaults.string(forKey: "ai.model") : nil) ?? selectedProvider.defaultModel
        if !isSending, !isRunningCommand, model != storedModel { model = storedModel }
        let voiceModel = defaults.string(forKey: "ai.voice.realtimeModel") ?? RealtimeVoiceModel.recommended
        if realtimeVoiceModel != voiceModel { realtimeVoiceModel = voiceModel }
        let mode = AgentPermissionMode.stored(in: defaults)
        if permissionMode != mode { permissionMode = mode }
    }


    func reloadPrograms(store: AgentProgramStore? = nil) {
        if let store { programStore = store }
        do { programs = try programStore.load(); programError = nil }
        catch { programError = error.localizedDescription }
    }

    func restoreProgramsBackup() {
        guard !isSending, !isRunningCommand else { return }
        do { programs = try programStore.restoreBackup(); programError = nil }
        catch { programError = "Backup could not be restored: " + error.localizedDescription }
    }

    func removeProgram(_ id: UUID) {
        guard !isSending, !isRunningCommand, programError == nil else { return }
        do {
            let updated = try programStore.load().filter { $0.id != id }
            try programStore.save(updated)
            programs = updated
        } catch { programError = error.localizedDescription }
    }

    func saveProgram(messageID: UUID) {
        guard !isSending, !isRunningCommand, programError == nil,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              let proposal = messages[index].programProposal, proposal.status == .pending,
              proposal.action == .save, let name = proposal.name, let summary = proposal.summary,
              let script = proposal.script, let directory = messages[index].commandDirectory,
              AgentProgram.valid(name: name, summary: summary, script: script) else { return }
        do {
            let program = AgentProgram(name: name, summary: summary, script: script, directory: directory)
            let updated = try programStore.load() + [program]
            try programStore.save(updated)
            programs = updated
            messages[index].programProposal?.status = .approved
            messages[index].text += "\n\nSaved to Programs: " + name
            persist()
        } catch { errorMessage = "Program could not be saved: " + error.localizedDescription }
    }

    func dismissProgram(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].programProposal?.status == .pending else { return }
        messages[index].programProposal?.status = .dismissed
        goal?.state = .paused
        goal?.detail = "The proposed program was dismissed."
        persist()
    }

    func requestReusableProgram() {
        guard !isSending, !isRunningCommand else { return }
        draft = "Turn the successful workflow we refined in this conversation into a reusable program. Preserve the final requirements and successful steps, explain prerequisites and side effects, and offer it for saving to Programs."
        send()
    }

    /// Explicit user action. Runs locally and never starts an AI follow-up.
    func runProgram(_ id: UUID, arguments: [String] = [], workingDirectory: String? = nil, proposalMessageID: UUID? = nil) {
        reloadPrograms()
        guard !isSending, !isRunningCommand, programError == nil,
              var program = programs.first(where: { $0.id == id }) else { return }
        if let workingDirectory { program.directory = workingDirectory }
        do {
            let command = try programStore.command(for: program, arguments: arguments)
            let message = AIMessage(role: .assistant, text: "Run program: " + program.name,
                commandProposal: AgentCommandProposal(summary: program.summary, command: command),
                commandDirectory: program.directory)
            if let proposalMessageID,
               let index = messages.firstIndex(where: { $0.id == proposalMessageID }) {
                guard messages[index].programProposal?.status == .pending else { return }
                messages[index].programProposal?.status = .approved
            }
            messages.append(message)
            runCommand(messageID: message.id, continueWithAgent: false)
        } catch { errorMessage = "Program could not run: " + error.localizedDescription }
    }

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
        if goal?.isUnfinished == true, agentDirectory != nil { return }
        agentDirectory = directory
    }

    /// Isolate Ask history per terminal tab. Switching tabs never shows another
    /// tab's agent thread.
    func bindTab(_ id: UUID) {
        if activeTabID == id {
            if !loaded { load() }
            return
        }
        if activeTabID == nil, messages.isEmpty, !isSending, !isRunningCommand {
            activeTabID = id
            loaded = false
            load()
            return
        }
        finalizeRealtimeVoiceMessages()
        stashCurrentTranscript()
        stop()
        pendingImages = imageDrafts[transcriptKey(tab: id, provider: selectedProvider)] ?? []
        pendingTerminalOutput = terminalOutputDrafts[transcriptKey(tab: id, provider: selectedProvider)]
        activeTabID = id
        goal = goals[transcriptKey(tab: id, provider: selectedProvider)]
        messages = transcripts[transcriptKey(tab: id, provider: selectedProvider)] ?? []
        loaded = true
        loadFailed = false
        errorMessage = nil
    }

    func discardTab(_ id: UUID) {
        for provider in AIBackendID.allCases {
            transcripts.removeValue(forKey: transcriptKey(tab: id, provider: provider))
            goals.removeValue(forKey: transcriptKey(tab: id, provider: provider))
            imageDrafts.removeValue(forKey: transcriptKey(tab: id, provider: provider))
            terminalOutputDrafts.removeValue(forKey: transcriptKey(tab: id, provider: provider))
        }
        guard activeTabID == id else { return }
        stop()
        pendingImages = []
        pendingTerminalOutput = nil
        activeTabID = nil
        messages = transcripts[transcriptKey(tab: unboundTabID, provider: selectedProvider)] ?? []
        loaded = true
    }

    /// Terminal → agent routing always starts a fresh thread for the active tab.
    func beginTerminalAgent(question: String, directory: URL?) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        goal = nil
        pendingImages = []
        pendingTerminalOutput = nil
        messages = []
        transcripts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = []
        webpage = nil
        webpages[selectedProvider] = nil
        draft = trimmed
        agentDirectory = directory
        errorMessage = nil
        loaded = true
        loadFailed = false
        send()
    }

    private func transcriptKey(tab: UUID, provider: AIBackendID) -> String {
        "\(tab.uuidString).\(provider.rawValue)"
    }

    private func stashCurrentTranscript() {
        goals[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = goal
        transcripts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = messages
        imageDrafts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = pendingImages
        terminalOutputDrafts[transcriptKey(tab: transcriptTabID, provider: selectedProvider)] = pendingTerminalOutput
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
    private let restoreConversation: Bool

    convenience init(provider: any AIProvider, credentials: any AICredentialStore,
                     conversations: any AIConversationStore, defaults: UserDefaults = .standard,
                     programStore: AgentProgramStore = .standard,
                     webpageFetcher: any WebpageFetching = WebpageFetcher(), restoreConversation: Bool = false) {
        self.init(backends: [AIBackend(id: .openai, provider: provider, credentials: credentials,
                                     conversations: conversations)], defaults: defaults, programStore: programStore,
                  webpageFetcher: webpageFetcher, restoreConversation: restoreConversation)
    }

    init(backends: [AIBackend], defaults: UserDefaults = .standard,
         programStore: AgentProgramStore = .standard,
         webpageFetcher: any WebpageFetching = WebpageFetcher(), restoreConversation: Bool = false) {
        precondition(!backends.isEmpty)
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) })
        self.defaults = defaults
        self.programStore = programStore
        self.webpageFetcher = webpageFetcher
        self.restoreConversation = restoreConversation
        let saved = AIBackendID(rawValue: defaults.string(forKey: "ai.provider") ?? "openai")
        let selected = backends.first(where: { $0.id == saved })?.id ?? backends[0].id
        self.selectedProvider = selected
        self.enabled = defaults.bool(forKey: "ai.enabled")
        self.permissionMode = AgentPermissionMode.stored(in: defaults)
        let legacy = selected == .openai ? defaults.string(forKey: "ai.model") : nil
        self.model = defaults.string(forKey: "ai.model.\(selected.rawValue)") ?? legacy ?? selected.defaultModel
        self.realtimeVoiceModel = defaults.string(forKey: "ai.voice.realtimeModel")
            ?? RealtimeVoiceModel.recommended
        reloadPrograms()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSharedPreferences() }
            .store(in: &sharedObservations)
        NotificationCenter.default.publisher(for: AgentProgramStore.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, note.object as? URL == self.programStore.directory else { return }
                self.reloadPrograms()
            }
            .store(in: &sharedObservations)
    }

    func selectProvider(_ id: AIBackendID) {
        guard id != selectedProvider, backends[id] != nil else { return }
        stop()
        finalizeRealtimeVoiceMessages()
        stashCurrentTranscript()
        drafts[selectedProvider] = draft
        webpages[selectedProvider] = webpage
        pendingImages = imageDrafts[transcriptKey(tab: transcriptTabID, provider: id)] ?? []
        pendingTerminalOutput = terminalOutputDrafts[transcriptKey(tab: transcriptTabID, provider: id)]
        selectedProvider = id
        goal = goals[transcriptKey(tab: transcriptTabID, provider: id)]
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

    deinit { task?.cancel(); commandTask?.cancel(); processMonitor?.cancel(); commandRunner?.cancel() }

    var canSend: Bool {
        enabled && !isSending && !isRunningCommand && !isUpdatingKey && !loadFailed && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty || pendingTerminalOutput != nil)
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
        let key = transcriptKey(tab: transcriptTabID, provider: selectedProvider)
        if let cached = transcripts[key] { messages = cached; goal = goals[key]; return }
        guard restoreConversation else { messages = []; return }
        do {
            messages = try conversations.load()
            goal = messages.last?.goalSnapshot
            agentDirectory = messages.reversed().compactMap(\.commandDirectory).first.map { URL(fileURLWithPath: $0) }
            if goal?.isUnfinished == true {
                if goal?.state != .stopped {
                    goal?.state = .paused
                    goal?.detail = "Restored checkpoint. Review the recorded results, then resume when ready. Interrupted actions were not replayed."
                }
                for index in (goal?.attempts ?? []).indices where goal?.attempts?[index].outcome == .pending {
                    goal?.attempts?[index].outcome = .interrupted
                    goal?.attempts?[index].observation = "Sora closed before a result was recorded. Effects are uncertain."
                }
            }
            stashCurrentTranscript()
        } catch {
            loadFailed = true
            errorMessage = "The saved task could not be read: " + error.localizedDescription
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

    var canSteer: Bool {
        enabled && (isSending || isRunningCommand) && goal?.isUnfinished == true && pendingImages.isEmpty && pendingTerminalOutput == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func queueSteering() {
        guard canSteer else { return }
        let update = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [goal?.pendingSteering, update].compactMap { $0 }.joined(separator: "\n")
        guard combined.utf8.count <= 12_000 else {
            errorMessage = "Keep the queued update under 12 KB."
            return
        }
        goal?.pendingSteering = combined
        draft = ""
        persist()
    }

    func removeQueuedSteering() {
        if draft.isEmpty { draft = goal?.pendingSteering ?? "" }
        goal?.pendingSteering = nil
        persist()
    }

    private func retirePendingActions() {
        for index in messages.indices {
            if messages[index].commandProposal?.status == .pending { messages[index].commandProposal?.status = .dismissed }
            if messages[index].webpageProposal?.status == .pending { messages[index].webpageProposal?.status = .dismissed }
            if messages[index].toolCall?.status == .pending { messages[index].toolCall?.status = .dismissed }
            if messages[index].programProposal?.status == .pending { messages[index].programProposal?.status = .dismissed }
        }
    }

    func send() {
        load()
        if isSending || isRunningCommand { queueSteering(); return }
        answeringQuestion = AgentGoal.requestsExplanation(draft)
        if answeringQuestion {
            if goal?.isUnfinished == true { goal?.state = .paused }
        } else if goal?.isUnfinished == true {
            goal?.state = .working
            goal?.corrections = 0
            let update = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !update.isEmpty { goal?.amendments = (goal?.amendments ?? []) + [update] }
            retirePendingActions()
        } else {
            goal = AgentGoal.requestsExecution(draft)
                ? AgentGoal(request: draft, firstMessageIndex: messages.count) : nil
            goal?.budget = defaultBudget
        }
        send(continuation: nil)
    }

    private func send(continuation: String?) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sora-transcript-stress-test") { return }
        #endif
        load()
        guard !isSending, !isRunningCommand, !isUpdatingKey else { return }
        guard enabled else { errorMessage = AIError.disabled.localizedDescription; return }
        guard !loadFailed else { return }
        var question = (continuation ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty, continuation == nil, !pendingImages.isEmpty { question = "What do you see in this image?" }
        if question.isEmpty, continuation == nil, pendingTerminalOutput != nil { question = "Explain this terminal output." }
        guard !question.isEmpty else { return }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedProvider.needsKey || !model.isEmpty else { errorMessage = AIError.invalidModel.localizedDescription; return }

        guard checkBudget() else { return }
        var outgoingGoal = goal
        let queuedSteering = outgoingGoal?.pendingSteering
        if let queuedSteering {
            question = queuedSteering + (continuation == nil ? "\n" + question : "")
            let amendments = (outgoingGoal?.amendments ?? []) + [queuedSteering]
            outgoingGoal?.amendments = amendments
            outgoingGoal?.pendingSteering = nil
            outgoingGoal?.corrections = 0
            outgoingGoal?.awaitingVerification = false
            outgoingGoal?.state = .working
            retirePendingActions()
        }
        do {
            // Send only complete question/answer pairs. Stopped or failed turns
            // stay visible locally but cannot masquerade as complete answers.
            var context = try AgentWorkingContext.recentPairs(in: messages)
            let compacted = context.count < messages.filter { $0.status == .complete }.count
            let user = AIMessage(role: .user, text: question, images: continuation == nil ? pendingImages : nil, webpage: continuation == nil ? webpage : nil, terminalOutput: continuation == nil ? pendingTerminalOutput : nil, isAgentContinuation: continuation != nil && queuedSteering == nil)
            context.append(user)
            let mentioned = ProgramMention.resolve(question, programs: programs)
            if !mentioned.isEmpty, programError == nil {
                let references = mentioned.map { ["id": $0.id.uuidString, "name": $0.name] }
                let data = try JSONSerialization.data(withJSONObject: references, options: [.sortedKeys])
                context[context.count - 1].text += "\n\nExplicit program mentions resolved by Sora (reference data): " + String(decoding: data, as: UTF8.self)
            }
            if !programs.isEmpty, programError == nil {
                let catalog = programs.map { ["id": $0.id.uuidString, "name": $0.name, "summary": $0.summary, "directory": $0.directory] }
                let data = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
                context[context.count - 1].text += "\n\nSaved Programs catalog (reference data):\n" + String(decoding: data, as: UTF8.self)
            }
            guard try context.reduce(0, { $0 + (try $1.contentForProvider()).utf8.count }) <= 100_000 else {
                throw AIError.contextTooLarge
            }
            guard context.flatMap({ $0.images ?? [] }).reduce(0, { $0 + $1.png.count }) <= 20_000_000 else { throw AIError.contextTooLarge }
            if let agentDirectory {
                context[context.count - 1].text += "\n\nAgent working directory: " + agentDirectory.path
            }
            if let outgoingGoal, !answeringQuestion {
                context[context.count - 1].text += try outgoingGoal.context(permission: permissionMode, messages: messages,
                    visibleEvidence: Set(context.map(\.id)))
                if compacted {
                    context[context.count - 1].text += "\nOlder turns remain saved locally. Recent attempts above are excerpts, not full evidence. Preserve the original goal and all constraints. If an omitted result is needed for verification, inspect the current state again using an authorized tool; never infer success from a summary."
                }
            }
            guard try context.reduce(0, { $0 + (try $1.contentForProvider()).utf8.count }) <= 100_000 else {
                throw AIError.contextTooLarge
            }
            if requiresCommandApproval {
                context[context.count - 1].text += "\nThis clip-preparation session requires approval for downloads, installations, webpage fetches and file changes, regardless of the global permission mode. Routine read-only commands can run automatically."
            }
            let response = AIMessage(role: .assistant, text: "", status: .streaming, commandDirectory: agentDirectory?.path)
            var updated = messages + [user, response]
            updated[updated.count - 1].goalSnapshot = outgoingGoal
            try conversations.save(updated)
            goal = outgoingGoal
            messages = updated
            if continuation == nil {
                pendingImages = []
                pendingTerminalOutput = nil
                draft = ""
                webpage = nil
                webpages[selectedProvider] = nil
            }
            errorMessage = nil
            isSending = true
            beginBudgetWork()
            let token = UUID()
            generation = token
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
                    for attempt in 0...3 {
                        guard let self, self.reserveRequest(currentRequest) else { return }
                        var completed = false
                        for try await event in provider.events(for: currentRequest, credential: key) {
                            try Task.checkCancellation()
                            guard self.generation == token else { return }
                            switch event {
                            case .text(let text):
                                guard let index = self.messages.firstIndex(where: { $0.id == response.id }) else { return }
                                self.messages[index].text += text
                                if !self.answeringQuestion { self.goal?.budget?.outputCharacters += text.count }
                            case .completed: completed = true
                            }
                        }
                        try Task.checkCancellation()
                        guard completed else { throw AIError.incompleteStream }
                        guard self.generation == token,
                              let index = self.messages.firstIndex(where: { $0.id == response.id }) else { return }
                        let text = self.messages[index].text
                        guard !text.isEmpty else { throw AIError.responseFailed }
                        guard AgentEnvelope.needsRepair(text), attempt < 3 else { break }
                        self.messages[index].recordRejectedAction(text, attempt: attempt + 1)
                        // Nothing is executed during repair. Include the rejected answer
                        // and concrete feedback so the model can correct it, not guess again.
                        var repairedContext = request.messages
                        let usedBytes = try repairedContext.reduce(0, { $0 + (try $1.contentForProvider()).utf8.count })
                        let feedback = attempt == 2
                            ? AgentEnvelope.explanationFallback + "\n" + AgentEnvelope.validationReasons(for: text).joined(separator: "\n")
                            : AgentEnvelope.repairFeedback(for: text, attempt: attempt + 1)
                        let remaining = max(0, 100_000 - usedBytes - feedback.utf8.count - 100)
                        let excerpt = String(decoding: Array(text.utf8.prefix(min(12_000, remaining))), as: UTF8.self)
                        if !excerpt.isEmpty {
                            repairedContext.append(AIMessage(role: .assistant, text: excerpt))
                        }
                        repairedContext.append(AIMessage(role: .user, text: feedback))
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

    #if DEBUG
    private var stressTestStarted = false

    /// Opt-in UI stress fixture. Uses no provider, credentials, or persistence.
    func startTranscriptStressTest() {
        guard ProcessInfo.processInfo.arguments.contains("--sora-transcript-stress-test"), !isSending, !stressTestStarted else { return }
        stressTestStarted = true
        goal = nil
        messages = (0..<150).flatMap { index in
            [AIMessage(role: .user, text: "Stress request \(index): inspect this output"),
             AIMessage(role: .assistant,
                text: "## Result \(index)\n" + String(repeating: "- A streaming layout test with **formatted text** and `code`.\n", count: 12),
                commandResult: AgentCommandResult(command: "fixture", directory: "/tmp",
                    output: String(repeating: "sample output line with enough text to wrap when resized\n", count: 100),
                    exitCode: 0, interrupted: false, truncated: false))]
        }
        messages.append(AIMessage(role: .user, text: "Stress test: streaming response"))
        messages.append(AIMessage(role: .assistant, text: "## Streaming stress test\n", status: .streaming))
        isSending = true
        task = Task { [weak self] in
            for index in 0..<240 {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard let self, let last = self.messages.indices.last else { return }
                self.messages[last].text += "- Chunk \(index): **formatted** content with `inline code` and wrapping text.\n"
            }
            guard let self, let last = self.messages.indices.last else { return }
            self.messages[last].status = .complete
            self.isSending = false
            self.task = nil
            print("SORA_TRANSCRIPT_STRESS_COMPLETE: 302 messages, 240 streaming updates; no provider or persistence")
        }
    }
    #endif

    func stop() {
        processMonitor?.cancel()
        processMonitor = nil
        finishBudgetWork()
        if goal?.isUnfinished == true {
            goal?.state = .stopped
            goal?.detail = "Stopped by you."
        }
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
        guard isSending else { persist(); return }
        isSending = false
        if let index = messages.lastIndex(where: { $0.status == .streaming }) {
            messages[index].status = .stopped
        }
        persist()
    }

    func newConversation() {
        pendingImages = []
        pendingTerminalOutput = nil
        stop()
        goal = nil
        messages = []
        goals.removeValue(forKey: transcriptKey(tab: transcriptTabID, provider: selectedProvider))
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
            goal?.state = .paused
            goal?.detail = "The proposed command was dismissed."
            persist()
        } catch {
            errorMessage = "The command decision could not be saved: \(error.localizedDescription)"
        }
    }

    func reportCommandUnavailable() {
        errorMessage = "Return to an empty, ready shell prompt before running this command."
    }

    private func finish(token: UUID, responseID: UUID, status: AIMessage.Status, error: String? = nil) {
        guard generation == token else { return }
        finishBudgetWork()
        generation = nil
        task = nil
        isSending = false
        if status == .complete, goal?.pendingSteering != nil {
            if let index = messages.firstIndex(where: { $0.id == responseID }) {
                messages[index].status = .stopped
                messages[index].text = "Applying your update before choosing the next action."
            }
            persist()
            guard errorMessage == nil else { return }
            send(continuation: "Apply the queued user update to the task before taking another action.")
            return
        }
        var envelopeError: String?
        var taskDecision: AgentTaskDecision?
        if let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].status = status
            if status == .complete {
                let text = messages[index].text
                if let decision = AgentTaskDecision.parse(text) {
                    taskDecision = decision
                    messages[index].taskDecision = decision
                    messages[index].text = decision.displayText
                } else if let call = AgentToolCall.parse(text) {
                    messages[index].text = call.summary
                    messages[index].toolCall = call
                } else if let match = AgentCommandProposalParser.match(text) {
                    messages[index].text = match.prose.isEmpty ? match.proposal.summary : match.prose
                    messages[index].commandProposal = match.proposal
                } else if let match = AgentWebpageProposalParser.match(text) {
                    messages[index].text = match.prose.isEmpty ? match.proposal.summary : match.prose
                    messages[index].webpageProposal = match.proposal
                } else if let match = AgentProgramProposal.match(text) {
                    if match.proposal.action == .run && !programs.contains(where: { $0.id == match.proposal.id }) {
                        messages[index].text = "That saved program is no longer in the catalog. Open Programs to choose an available program."
                        taskDecision = AgentTaskDecision(kind: .pause, summary: messages[index].text)
                    } else {
                        messages[index].text = match.prose.isEmpty ? (match.proposal.summary ?? "Use a saved program") : match.prose
                        messages[index].programProposal = match.proposal
                    }
                } else if AgentEnvelope.needsRepair(text) {
                    messages[index].recordRejectedAction(text, attempt: 4)
                    // Never leave Sora's wire format in the transcript. Say what
                    // happened instead of silently dropping the request.
                    let prose = AgentCommandProposalParser.proseBeforeEnvelope(in: text)
                        ?? AgentWebpageProposalParser.proseBeforeEnvelope(in: text)
                        ?? AgentEnvelope.proseBeforeEnvelope(in: text, opening: AgentProgramProposal.openingTag)
                        ?? ""
                    messages[index].text = [prose, "Sora rejected the assistant’s action: " + AgentEnvelope.validationReasons(for: text).joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    messages[index].status = .failed
                    envelopeError = "The assistant’s action format was invalid after two repair attempts and a final explanation request. No action was run. See the validation details above."
                }
            }
        }
        errorMessage = error ?? envelopeError
        persist()
        guard status == .complete, errorMessage == nil else {
            if goal?.isUnfinished == true, status != .stopped {
                goal?.state = .paused
                goal?.detail = errorMessage ?? "The response did not complete."
                persist()
            }
            return
        }
        let message = messages.first(where: { $0.id == responseID })
        if message?.commandProposal != nil || message?.webpageProposal != nil || message?.programProposal != nil || message?.toolCall != nil {
            ensureGoal()
            answeringQuestion = false
            goal?.detail = message?.text ?? "Preparing an action"
            goal?.state = .waitingForApproval
        } else if let taskDecision {
            ensureGoal()
            let continuation: String?
            if !usesCompletionGate, taskDecision.kind == .complete {
                goal?.state = .completed
                goal?.detail = taskDecision.summary
                continuation = nil
            } else { continuation = goal?.decide(taskDecision, messages: messages) }
            persist()
            if let continuation { send(continuation: continuation) }
            return
        } else if usesCompletionGate, goal?.isUnfinished == true, !answeringQuestion {
            let continuation = goal?.correct("The last response did not establish completion or identify a concrete blocker.")
            persist()
            if let continuation { send(continuation: continuation) }
            return
        }
        if let call = message?.toolCall, let directory = agentDirectory,
           call.canRunAutomatically(mode: permissionMode, directory: directory, grants: goal?.readGrants ?? []) {
            runTool(messageID: responseID)
        } else if agentDirectory != nil,
           let proposal = message?.commandProposal,
           AgentCommandPermission.shouldAutoRunCommand(proposal.command, mode: commandPermissionMode) {
            runCommand(messageID: responseID)
        } else if message?.webpageProposal != nil,
                  AgentCommandPermission.shouldAutoFetchWebpage(mode: commandPermissionMode) {
            fetchWebpage(messageID: responseID)
        }
        persist()
    }

    private func ensureGoal() {
        guard goal == nil || goal?.state == .completed,
              let index = messages.lastIndex(where: { $0.role == .user && $0.isAgentContinuation != true }) else { return }
        goal = AgentGoal(request: messages[index].text, firstMessageIndex: index)
        goal?.budget = defaultBudget
    }

    /// Permission remains independent: this gate prevents ineffective repeats,
    /// and never changes an action's approval status to approved.
    private func beginAttempt(messageID: UUID, action: String, directory: String,
                              replaySafety: AgentAttempt.ReplaySafety? = nil) -> Bool {
        if let reason = goal?.beginAttempt(id: messageID, action: action, directory: directory, replaySafety: replaySafety) {
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].commandProposal?.status = .dismissed
                messages[index].webpageProposal?.status = .dismissed
                messages[index].toolCall?.status = .dismissed
                messages[index].text += "\n\nSora did not repeat this action: " + reason
            }
            let continuation = goal?.correct(reason)
            persist()
            if errorMessage == nil, let continuation { send(continuation: continuation) }
            return false
        }
        persist()
        return errorMessage == nil
    }

    private func checkBudget(action: Bool = false) -> Bool {
        guard goal != nil, !answeringQuestion else { return true }
        if goal?.budget == nil { goal?.budget = defaultBudget }
        if let reason = goal?.budget?.limitReason(action: action) {
            pauseForBudget(reason)
            return false
        }
        return true
    }

    private func reserveRequest(_ request: AIRequest) -> Bool {
        guard checkBudget() else { return false }
        if goal != nil, !answeringQuestion {
            goal?.budget?.requests += 1
            let characters = request.messages.reduce(AIRequest.instructions.count) { $0 + ((try? $1.contentForProvider().count) ?? 0) }
            goal?.budget?.inputCharacters += characters
            persist()
        }
        return errorMessage == nil
    }

    private func beginBudgetWork() {
        guard goal != nil, !answeringQuestion else { return }
        budgetWorkStarted = Date()
        let remaining = goal?.budget?.remainingSeconds ?? 0
        budgetDeadline?.cancel()
        budgetDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000)) }
            catch { return }
            self?.pauseForBudget("The task reached its active time limit.")
        }
    }

    private func finishBudgetWork() {
        budgetDeadline?.cancel()
        budgetDeadline = nil
        if let start = budgetWorkStarted { goal?.budget?.activeSeconds += max(0, Date().timeIntervalSince(start)) }
        budgetWorkStarted = nil
    }

    private func pauseForBudget(_ reason: String) {
        stop()
        goal?.state = .paused
        goal?.budgetPauseReason = reason
        goal?.detail = reason + " Progress is saved. Extend the budget to continue."
        errorMessage = goal?.detail
        persist()
    }

    func extendGoalBudget() {
        guard goal?.isUnfinished == true, goal?.budgetPauseReason != nil,
              !isSending, !isRunningCommand else { return }
        goal?.budget?.extend()
        goal?.budgetPauseReason = nil
        errorMessage = nil
        persist()
        guard errorMessage == nil else { return }
        resumeGoal()
    }

    func resumeGoal() {
        guard enabled, !isSending, !isRunningCommand, goal?.isUnfinished == true else { return }
        answeringQuestion = false
        goal?.state = .working
        goal?.corrections = 0
        send(continuation: "Resume the original goal from the recorded results. Verify before replaying any action.")
    }

    func dismissTool(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].toolCall?.status == .pending else { return }
        messages[index].toolCall?.status = .dismissed
        goal?.state = .paused
        goal?.detail = "The proposed inspection was dismissed."
        persist()
    }

    func revokeReadGrants() {
        goal?.readGrants = []
        persist()
    }

    func runTool(messageID: UUID, remember: Bool = false) {
        guard enabled, !isSending, !isRunningCommand,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              var call = messages[index].toolCall, call.status == .pending,
              let directory = agentDirectory, checkBudget(action: true) else { return }
        let identity = call.identity(directory: directory)
        guard beginAttempt(messageID: messageID, action: identity, directory: directory.path, replaySafety: call.tool.replaySafety) else { return }
        if remember { goal?.readGrants = Array(Set((goal?.readGrants ?? []) + [identity])) }
        call.approvedPath = call.resolvedURL(directory: directory).path
        call.status = .approved
        messages[index].toolCall = call
        messages[index].commandState = "running"
        goal?.budget?.actions += 1
        persist()
        guard errorMessage == nil else { return }
        let token = UUID()
        commandGeneration = token
        commandStopRequested = false
        isRunningCommand = true
        runningMessageID = messageID
        beginBudgetWork()
        commandTask = Task { [weak self] in
            let result: AgentToolResult
            do {
                if call.tool == .importSkin {
                    guard let library = self?.skinLibrary else { throw SkinLibrary.failure("The skin library is unavailable in this session.") }
                    let target = call.resolvedURL(directory: directory)
                    guard target.path == call.approvedPath else { throw SkinLibrary.failure("The file path changed after approval.") }
                    let skin = try await library.add(target)
                    result = AgentToolResult(tool: call.tool, path: target.path,
                        output: "Imported and selected \(skin.name). Sora retained its own copy. Video starts muted.", failed: false, truncated: false)
                } else { result = try await AgentToolRegistry.run(call, directory: directory) }
            }
            catch { result = AgentToolResult(tool: call.tool, path: call.approvedPath ?? call.path,
                output: error is CancellationError ? "Inspection canceled." : error.localizedDescription,
                failed: true, truncated: false) }
            guard let self, self.commandGeneration == token else { return }
            let stopped = self.commandStopRequested || Task.isCancelled
            if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                self.messages[index].toolResult = result
                self.messages[index].commandState = stopped ? "stopped" : "finished"
            }
            self.goal?.finishAttempt(id: messageID, outcome: stopped ? .interrupted : (result.failed ? .failed : .succeeded),
                observation: (result.truncated ? "Truncated: " : "") + result.output)
            self.finishAgentAction(token: token)
            guard !stopped, self.errorMessage == nil else { return }
            self.send(continuation: "Inspect the actual tool result against the original goal. If it failed, use the error to choose a different approach. If truncated, request a smaller range or narrower search before claiming exhaustive results. Continue with a concrete action or supported completion.")
        }
    }

    func dismissWebpage(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].webpageProposal,
              proposal.status == .pending
        else { return }
        proposal.status = .dismissed
        messages[index].webpageProposal = proposal
        goal?.state = .paused
        goal?.detail = "The proposed webpage fetch was dismissed."
        persist()
    }

    func fetchWebpage(messageID: UUID) {
        guard enabled, !isSending, !isRunningCommand,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].webpageProposal,
              proposal.status == .pending
        else { return }
        guard checkBudget(action: true) else { return }
        guard beginAttempt(messageID: messageID, action: "Fetch " + proposal.url, directory: "", replaySafety: .readOnly) else { return }
        proposal.status = .approved
        messages[index].webpageProposal = proposal
        messages[index].commandState = "fetching"
        persist()
        goal?.budget?.actions += 1
        beginBudgetWork()
        persist()
        guard errorMessage == nil else { finishBudgetWork(); return }
        goal?.state = .working
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
                self.goal?.finishAttempt(id: messageID, outcome: stoppedByUser ? .interrupted : .succeeded,
                                         observation: page.text)
                self.finishAgentAction(token: token)
                guard self.errorMessage == nil, !stoppedByUser else { return }
                self.send(continuation: "Review the webpage snapshot against the user’s requested goal. If it is not achieved, propose the next concrete action now: inspect relevant links or use a shell command to inspect source/assets when a text snapshot is insufficient. Do not stop at summarizing the snapshot or offer to continue later. Only report completion when supported by results, or explain a specific blocker.")
            } catch {
                guard let self, self.commandGeneration == token else { return }
                let stoppedByUser = self.commandStopRequested || error is CancellationError
                if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[index].webpageProposal?.status = .failed
                    self.messages[index].commandState = stoppedByUser ? "stopped" : "failed"
                }
                self.goal?.finishAttempt(id: messageID, outcome: stoppedByUser ? .interrupted : .failed,
                                         observation: error.localizedDescription)
                self.finishAgentAction(token: token)
                guard self.errorMessage == nil, !stoppedByUser else { return }
                self.send(continuation: "The webpage fetch failed (\(error.localizedDescription)). Continue with a different public HTTPS URL or answer without it.")
            }
        }
    }

    private func finishAgentAction(token: UUID) {
        guard commandGeneration == token else { return }
        finishBudgetWork()
        commandStopRequested = false
        isRunningCommand = false
        commandRunner = nil
        commandTask = nil
        commandGeneration = nil
        runningMessageID = nil
        persist()
    }

    func runCommand(messageID: UUID, continueWithAgent: Bool = true) {
        guard (enabled || !continueWithAgent), !isSending, !isRunningCommand,
              let message = messages.first(where: { $0.id == messageID }),
              message.commandProposal?.status == .pending,
              let path = message.commandDirectory ?? agentDirectory?.path else { return }
        let directory = URL(fileURLWithPath: path)
        agentDirectory = directory
        guard checkBudget(action: true) else { return }
        if continueWithAgent {
            guard let command = message.commandProposal?.command,
                  beginAttempt(messageID: messageID, action: command, directory: path) else { return }
        }
        guard let proposal = approveCommand(messageID: messageID) else { return }
        goal?.budget?.actions += 1
        beginBudgetWork()
        persist()
        guard errorMessage == nil else { finishBudgetWork(); return }
        goal?.state = .working
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
        let timeout = continueWithAgent ? min(commandTimeout, goal?.budget?.remainingSeconds ?? commandTimeout) : 60
        persist()
        guard errorMessage == nil else { finishAgentAction(token: token); return }
        monitorProcess(runner, token: token, messageID: messageID)
        commandTask = Task { [weak self] in
            do {
                let result = try await runner.run(command: proposal.command, directory: directory, timeout: timeout)
                guard let self, self.commandGeneration == token else { return }
                let stoppedByUser = self.commandStopRequested
                self.finishCommand(token: token, messageID: messageID, result: result, error: nil)
                guard self.errorMessage == nil else { return }
                if stoppedByUser {
                    return
                }
                if result.interrupted, continueWithAgent {
                    self.send(continuation: "The command reached its deadline and was stopped. Inspect the captured output and any possible side effects before retrying. Choose a smaller action or another approach; never assume a timed-out write did nothing. A necessary unavailable interaction requires a focused question.")
                } else if result.interrupted {
                    self.errorMessage = "Command stopped after reaching its time limit. Send a follow-up to continue."
                    self.goal?.state = .paused
                    self.goal?.detail = self.errorMessage ?? "Command time limit reached."
                    self.persist()
                } else if continueWithAgent {
                    self.send(continuation: "Review the actual command result against the original goal and every criterion. Propose the next concrete action if anything remains. Only propose SORA_TASK completion with actual evidence after verification.")
                }
            } catch {
                guard let self, self.commandGeneration == token else { return }
                let stoppedByUser = self.commandStopRequested || error is CancellationError
                let result = AgentCommandResult(
                    command: proposal.command,
                    directory: directory.path,
                    output: stoppedByUser ? "" : "Command could not start: " + error.localizedDescription,
                    exitCode: stoppedByUser ? 137 : 125,
                    interrupted: stoppedByUser,
                    truncated: false
                )
                self.finishCommand(
                    token: token,
                    messageID: messageID,
                    result: result,
                    error: nil
                )
                if !stoppedByUser, continueWithAgent, self.errorMessage == nil {
                    self.send(continuation: "The command could not start. Use the recorded launch error to inspect prerequisites or choose another valid working directory/action. Do not repeat the same failed proposal unchanged.")
                }
            }
        }
    }

    private func monitorProcess(_ runner: AgentCommandRunner, token: UUID, messageID: UUID) {
        processMonitor?.cancel()
        processMonitor = Task { [weak self] in
            var delay: UInt64 = 250_000_000
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, self.commandGeneration == token,
                      let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                if let progress = runner.snapshot() {
                    self.messages[index].processProgress = progress
                    if progress.running { self.goal?.detail = progress.status }
                    self.persist()
                    if self.errorMessage != nil { self.stop(); return }
                }
                delay = min(delay * 2, 4_000_000_000)
            }
        }
    }

    private func finishCommand(token: UUID, messageID: UUID, result: AgentCommandResult?, error: String?) {
        guard commandGeneration == token else { return }
        processMonitor?.cancel()
        processMonitor = nil
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].processProgress = commandRunner?.snapshot()
        }
        finishBudgetWork()
        let stoppedByUser = commandStopRequested
        commandStopRequested = false
        isRunningCommand = false
        commandRunner = nil
        commandTask = nil
        commandGeneration = nil
        runningMessageID = nil
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            if let result {
                goal?.finishAttempt(id: messageID,
                    outcome: (stoppedByUser || result.interrupted) ? .interrupted : (result.exitCode == 0 ? .succeeded : .failed),
                    observation: "exit \(result.exitCode)" + (result.truncated ? " (output truncated)\n" : "\n") + result.output)
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
        guard !loadFailed else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sora-transcript-stress-test") { return }
        #endif
        for index in messages.indices.dropLast() { messages[index].goalSnapshot = nil }
        if let index = messages.indices.last {
            var checkpoint = goal
            if let started = budgetWorkStarted { checkpoint?.budget?.activeSeconds += max(0, Date().timeIntervalSince(started)) }
            messages[index].goalSnapshot = checkpoint
        }
        stashCurrentTranscript()
        do { try conversations.save(messages) }
        catch { errorMessage = "The conversation could not be saved: \(error.localizedDescription)" }
    }
}
