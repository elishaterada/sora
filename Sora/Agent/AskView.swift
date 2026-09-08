import AppKit
import SwiftUI

struct AskView: View {
    @ObservedObject var session: AskSession
    var inline = false
    var onClose: (() -> Void)?
    var onRunCommand: ((UUID) -> Void)?
    @StateObject private var voiceInput = VoiceInputController()
    @StateObject private var realtimeVoice = RealtimeVoiceController()
    @State private var transcriptLimit = 40
    @State private var showsPrograms = false
    @State private var programDirectories: [UUID: String] = [:]
    @State private var programArguments: [UUID: String] = [:]
    @State private var dictationPrefix = ""
    @State private var realtimeStartError: String?
    @FocusState private var composerFocused: Bool

    private var visibleMessages: [AIMessage] {
        session.messages.filter { $0.isAgentContinuation != true }
    }

    private var conversationTitle: String? {
        visibleMessages.first(where: { $0.role == .user })?.text
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if realtimeVoice.isActive || realtimeVoice.errorMessage != nil || realtimeStartError != nil {
                realtimeVoiceBar
            }
            Group {
                ScrollView {
                    // Avoid LazyVStack placement feedback during streaming and
                    // disclosure expansion. Bound eager layout; retain full history.
                    VStack(alignment: .leading, spacing: 18) {
                        if visibleMessages.count > transcriptLimit {
                            Button("Show earlier messages") { transcriptLimit += 40 }
                                .buttonStyle(.borderless)
                        }
                        if visibleMessages.isEmpty {
                            emptyState
                        }
                        ForEach(Array(visibleMessages.suffix(transcriptLimit))) { message in
                            messageView(message)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, SoraTheme.gridPaddingX)
                    .padding(.vertical, SoraTheme.space3)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }


            }

            if let error = session.errorMessage {
                Text(error).font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SoraTheme.gridPaddingX).padding(.bottom, SoraTheme.space2)
                    .accessibilityLabel("Agent error: \(error)")
            }

            Divider().opacity(0.35)
            composer
            statusBar
        }
        .background(inlineBackground)
        .frame(minWidth: inline ? 0 : 540, minHeight: inline ? 0 : 560)
        .preferredColorScheme(.dark)
        .tint(SoraTheme.accent)
        .sheet(isPresented: $showsPrograms) {
            AgentProgramsView(session: session)
        }
        .onAppear {
            session.load()
            #if DEBUG
            Task { @MainActor in
                await Task.yield()
                session.startTranscriptStressTest()
            }
            #endif
        }
        .onChange(of: session.activeTabID) { _ in transcriptLimit = 40 }
        .onChange(of: session.selectedProvider) { _ in
            transcriptLimit = 40
            voiceInput.stop()
            realtimeVoice.stop()
        }
        .onChange(of: session.enabled) { enabled in
            if !enabled { realtimeVoice.stop() }
        }
        .onDisappear {
            // Do not stop the stream — Escape / hide is a glance, not a cancel.
            voiceInput.stop()
            // Live microphone and speaker access always ends when Agent is hidden.
            realtimeVoice.stop()
        }
        .onChange(of: voiceInput.transcript) { transcript in
            guard !transcript.isEmpty else { return }
            session.draft = dictationPrefix + transcript
        }
    }

    private var inlineBackground: some View {
        ZStack {
            // Hybrid overlay: grid stays visible underneath.
            Color.black.opacity(inline ? 0.42 : 0.88)
            if inline {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.55)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            if inline {
                Rectangle()
                    .fill(SoraTheme.hairlineStrong)
                    .frame(height: 1)
            }
            HStack(spacing: 10) {
                if inline {
                    Button {
                        onClose?()
                    } label: {
                        HStack(spacing: SoraTheme.space1) {
                            Image(systemName: "chevron.left")
                            Text("ESC for terminal")
                        }
                        .font(SoraTheme.agentCaption.weight(.semibold))
                        .foregroundStyle(SoraTheme.accent)
                    }
                    .buttonStyle(SoraChromeButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Return to the terminal session. The agent keeps working in the background.")
                    .accessibilityLabel("Return to terminal")
                } else {
                    Text("Agent").font(SoraTheme.agentBodySemibold)
                }

                Spacer(minLength: SoraTheme.space2)

                if inline, let title = conversationTitle, !title.isEmpty {
                    ContextChip(
                        title: AgentResumeSummary.title(from: title),
                        help: title,
                        actions: [
                            ContextChipAction(title: "Copy Title") {
                                PathActions.copy(AgentResumeSummary.title(from: title))
                            },
                            ContextChipAction(title: "Copy Prompt") {
                                PathActions.copy(title)
                            }
                        ]
                    )
                    .font(SoraTheme.agentCaption)
                    .foregroundStyle(SoraTheme.muted)
                    .frame(maxWidth: 280)
                }

                Spacer(minLength: SoraTheme.space2)

                Button("Programs", systemImage: "terminal") {
                    session.reloadPrograms()
                    showsPrograms = true
                }
                .buttonStyle(.borderless)
                .help("Review and run saved programs without using AI tokens")

                Button {
                    toggleRealtimeVoice()
                } label: {
                    Image(systemName: realtimeVoice.isActive ? "waveform.circle.fill" : "waveform.circle")
                        .frame(width: SoraTheme.hitCompact, height: SoraTheme.hitCompact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(realtimeVoice.isActive ? SoraTheme.accent : .secondary)
                .disabled(!realtimeVoice.isActive && (!session.realtimeVoiceAvailability.isAvailable
                          || session.isSending || session.isRunningCommand))
                .help(realtimeVoice.isActive ? "End voice conversation"
                      : session.realtimeVoiceAvailability.reason ?? "Start realtime voice conversation")
                .accessibilityLabel(realtimeVoice.isActive ? "End voice conversation" : "Start voice conversation")

                if !inline {
                    Button("Clear Conversation") { clearConversation() }
                        .disabled(session.messages.isEmpty)
                }
                Menu {
                    Button("Save Workflow as Program…") { session.requestReusableProgram() }
                        .disabled(session.messages.isEmpty || !session.enabled || session.isSending || session.isRunningCommand)
                    Button("Agent Settings…") { SoraSettingsOpener.open() }
                    Button("Clear Conversation") { clearConversation() }
                        .disabled(session.messages.isEmpty)
                    if !inline {
                        Button("Close", role: .cancel) { onClose?() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: SoraTheme.hitCompact, height: SoraTheme.hitCompact)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Conversation options")
                .accessibilityLabel("Conversation options")
            }
            .padding(.horizontal, SoraTheme.gridPaddingX)
            .padding(.vertical, inline ? SoraTheme.space2 : SoraTheme.space3)
        }
    }

    private var realtimeVoiceBar: some View {
        HStack(spacing: SoraTheme.space2) {
            Image(systemName: realtimeVoice.isActive ? "waveform" : "exclamationmark.circle")
                .foregroundStyle(realtimeVoice.isActive ? SoraTheme.accent : SoraTheme.danger)
            Text(realtimeVoice.errorMessage ?? realtimeStartError ?? realtimeVoice.state.title)
                .font(SoraTheme.agentCaption)
                .foregroundStyle(realtimeVoice.isActive ? .primary : SoraTheme.danger)
            if let notice = realtimeVoice.audioNotice {
                Text(notice)
                    .font(SoraTheme.agentCaption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if realtimeVoice.isActive {
                Text(session.realtimeVoiceModel)
                    .font(SoraTheme.agentCaption2.monospaced())
                    .foregroundStyle(.tertiary)
                Button("End") { realtimeVoice.stop() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Voice Settings…") { SoraSettingsOpener.open(page: .voice) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, SoraTheme.gridPaddingX)
        .padding(.vertical, SoraTheme.space2)
        .background(SoraTheme.fillCard)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func toggleRealtimeVoice() {
        if realtimeVoice.isActive {
            realtimeVoice.stop()
            return
        }
        voiceInput.stop()
        realtimeStartError = nil
        Task {
            do {
                let key = try await session.realtimeVoiceCredential()
                await realtimeVoice.start(
                    apiKey: key,
                    model: session.realtimeVoiceModel,
                    onBeginMessage: { session.beginRealtimeVoiceMessage(role: $0) },
                    onUpdateMessage: { session.updateRealtimeVoiceMessage(id: $0, text: $1, completed: $2) },
                    onStopMessage: { session.stopRealtimeVoiceMessage(id: $0) }
                )
            } catch {
                realtimeStartError = error.localizedDescription
            }
        }
    }

    private func clearConversation() {
        voiceInput.stop()
        realtimeVoice.stop()
        session.newConversation()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: SoraTheme.space2) {
            Text(inline ? "New agent conversation" : "What would you like to do?")
                .font(SoraTheme.agentBodySemibold)
            Text(inline
                 ? "Ask anything about this tab’s terminal. Escape returns to the same prompt — the agent keeps working."
                 : "Ask about a command, describe a task, or paste an error you want help understanding.")
                .font(SoraTheme.agentCaption)
                .foregroundStyle(SoraTheme.muted)
            // Inline is the only live path; keep an example here so first-run isn’t empty.
            Button("How do I find the largest files in a folder?") {
                session.draft = "How do I find the largest files in a folder on macOS?"
                composerFocused = true
            }
            .buttonStyle(.link)
            .font(SoraTheme.agentBody)
            .tint(SoraTheme.accent)
            if !session.enabled {
                Button("Configure Agent…") { SoraSettingsOpener.open() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, inline ? SoraTheme.space2 : 28)
    }

    private var mentionMatches: [AgentProgram] {
        guard let query = ProgramMention.query(in: session.draft) else { return [] }
        return session.programs.filter {
            query.isEmpty || ProgramMention.handle($0, in: session.programs).contains(query)
                || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private func insertMention(_ program: AgentProgram) {
        session.draft = ProgramMention.inserting(program, into: session.draft, programs: session.programs)
        composerFocused = true
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: SoraTheme.space2) {
            if ProgramMention.query(in: session.draft) != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mention a program · Return selects the first match")
                        .font(SoraTheme.agentCaption).foregroundStyle(.secondary)
                    if mentionMatches.isEmpty {
                        Text("No matching saved programs").font(SoraTheme.agentCaption)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(mentionMatches) { program in
                                Button { insertMention(program) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("@" + ProgramMention.handle(program, in: session.programs))
                                        Text(program.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                }.buttonStyle(.plain)
                                .accessibilityLabel("Mention program " + program.name)
                            }
                        }
                    }.frame(height: CGFloat(min(mentionMatches.count, 4)) * 52)
                }
            }
            TextField(inline ? "Ask a follow up, or @mention a program…" : "Ask a question, or @mention a program…",
                      text: $session.draft, axis: inline ? .horizontal : .vertical)
                .font(SoraTheme.agentBody)
                .lineLimit(inline ? 1...3 : 2...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .accessibilityLabel("Question")
                .onSubmit { submitComposer() }
            HStack {
                if !inline {
                    Text(session.selectedProvider.disclosure)
                        .font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
                } else {
                    Text("↵ send")
                        .font(SoraTheme.agentCaption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    if voiceInput.isListening {
                        voiceInput.stop()
                    } else {
                        dictationPrefix = session.draft.isEmpty || session.draft.hasSuffix(" ")
                            ? session.draft : session.draft + " "
                        voiceInput.toggle()
                    }
                } label: {
                    Image(systemName: voiceInput.isListening ? "waveform.circle.fill" : "mic")
                }
                .buttonStyle(.borderless)
                .help(voiceInput.isListening ? "Stop dictating" : "Dictate into Agent")
                .accessibilityLabel(voiceInput.isListening ? "Stop dictating" : "Dictate into Agent")
                if session.isSending || session.isRunningCommand {
                    Button("Stop", systemImage: "stop.fill") { session.stop() }
                } else {
                    Button("Send", systemImage: "arrow.up") { submitComposer() }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(!session.canSend)
                }
            }
            if let error = voiceInput.errorMessage {
                Text(error).font(SoraTheme.agentCaption2).foregroundStyle(SoraTheme.danger)
            }
        }
        .padding(.horizontal, SoraTheme.gridPaddingX)
        .padding(.top, 10)
        .padding(.bottom, inline ? 6 : SoraTheme.space4)
    }

    private func submitComposer() {
        if let first = mentionMatches.first { insertMention(first); return }
        guard session.canSend else { return }
        voiceInput.stop()
        realtimeVoice.stop()
        session.send()
    }

    private var statusBar: some View {
        HStack(spacing: SoraTheme.space2) {
            if let directory = session.agentDirectory {
                ContextChip(
                    title: StickyPromptBarModel.displayPath(for: directory),
                    systemImage: "folder",
                    help: directory.path,
                    actions: ContextChipActions.path(directory)
                )
                if let branch = GitRepository.branchName(containing: directory) {
                    ContextChip(
                        title: branch,
                        systemImage: "arrow.triangle.branch",
                        help: "Branch \(branch)",
                        actions: ContextChipActions.branch(
                            branch,
                            repositoryRoot: GitRepository.root(containing: directory)
                        )
                    )
                }
                Text("·").foregroundStyle(.tertiary)
            }
            Text(session.selectedProvider.name)
                .lineLimit(1)
            Button {
                SoraSettingsOpener.open()
            } label: {
                Text(session.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "Choose model"
                      : session.model)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoraChromeButtonStyle())
            .help("Open Agent settings")
            .accessibilityLabel("Open Agent settings")
            Spacer(minLength: 0)
            if !inline {
                Text(session.selectedProvider.disclosure)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(SoraTheme.agentCaption2)
        .foregroundStyle(SoraTheme.muted)
        .padding(.horizontal, SoraTheme.gridPaddingX)
        .padding(.bottom, 10)
    }

    private func streamingEnvelope(_ text: String) -> (prose: String, title: String)? {
        if let prose = AgentCommandProposalParser.proseBeforeEnvelope(in: text) {
            return (prose, "Preparing a command…")
        }
        if let prose = AgentWebpageProposalParser.proseBeforeEnvelope(in: text) {
            return (prose, "Preparing a webpage…")
        }
        if let prose = AgentEnvelope.proseBeforeEnvelope(in: text, opening: AgentProgramProposal.openingTag) {
            return (prose, "Preparing a reusable program…")
        }
        return nil
    }

    private func messageView(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: SoraTheme.space2) {
            if message.role == .user {
                userPrompt(message.text, voice: message.isVoiceInput == true)
            } else {
                HStack {
                    Text("Sora").font(SoraTheme.agentCaption.weight(.semibold)).foregroundStyle(SoraTheme.muted)
                    Spacer()
                    if !message.text.isEmpty {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(SoraTheme.agentCaption)
                    }
                }
                if message.text.isEmpty && message.status == .streaming {
                    InlineProgressLabel(title: "Thinking…")
                } else if message.status == .streaming,
                          let pending = streamingEnvelope(message.text) {
                    // Show what the model wrote, never the envelope forming
                    // behind it.
                    if !pending.prose.isEmpty {
                        AgentMarkdownText(
                            text: pending.prose,
                            relativeTo: session.agentDirectory,
                            streaming: true
                        ).equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    InlineProgressLabel(title: pending.title)
                } else {
                    AgentMarkdownText(
                        text: message.text,
                        relativeTo: session.agentDirectory,
                        streaming: message.status == .streaming
                    ).equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let proposal = message.programProposal {
                programCard(proposal, message: message)
            }
            if let proposal = message.commandProposal {
                commandCard(proposal, messageID: message.id)
            }
            if let proposal = message.webpageProposal {
                webpageCard(proposal, messageID: message.id)
            }
            if let page = message.webpage {
                DisclosureGroup("Webpage: \(page.title)") {
                    VStack(alignment: .leading, spacing: SoraTheme.space2) {
                        Text(page.url.absoluteString).font(SoraTheme.agentCaption).textSelection(.enabled)
                        if page.isExcerpt { Text("Excerpt from page").font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted) }
                        Text(page.text).font(SoraTheme.agentBody).textSelection(.enabled)
                    }
                }
            }
            if let state = message.commandState, state == "stopped" || state == "failed" {
                Text((message.webpageProposal == nil ? "Command " : "Fetch ") + state)
                    .font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
            }
            if let result = message.commandResult {
                DisclosureGroup("Command output · exit \(result.exitCode)" + (result.truncated ? " · excerpt" : "")) {
                    LinkedText(
                        text: result.output.isEmpty ? "No output" : result.output,
                        relativeTo: session.agentDirectory,
                        monospaced: true
                    )
                }
            }
            if session.isRunningCommand, message.id == session.messages.last?.id {
                InlineProgressLabel(
                    title: message.commandState == "stopped" ? "Stopping…"
                    : message.commandState == "fetching" ? "Fetching webpage…"
                    : "Running command…"
                )
            }
            if message.status == .stopped || message.status == .failed {
                Text(message.status == .stopped ? "Stopped — partial answer" : "Answer incomplete")
                    .font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
            }
        }
    }

    private func programCard(_ proposal: AgentProgramProposal, message: AIMessage) -> some View {
        let saved = session.programs.first { $0.id == proposal.id }
        return VStack(alignment: .leading, spacing: 10) {
            Text(proposal.action == .save ? "Save reusable program" : "Run saved program")
                .font(SoraTheme.agentBodySemibold)
            Text(proposal.name ?? saved?.name ?? "Program unavailable")
            Text(proposal.summary ?? saved?.summary ?? "")
                .font(SoraTheme.agentCaption).foregroundStyle(.secondary)
            Text("Working directory: " + ((proposal.action == .run ? (programDirectories[message.id] ?? saved?.directory) : message.commandDirectory) ?? "Unavailable"))
                .font(SoraTheme.agentCaption).textSelection(.enabled)
            DisclosureGroup("Review zsh script") {
                Text(proposal.script ?? saved?.script ?? "Program removed from catalog")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            if proposal.status == .pending && proposal.action == .run {
                ProgramDirectoryPicker(directory: Binding(
                    get: { programDirectories[message.id] ?? saved?.directory ?? "" },
                    set: { programDirectories[message.id] = $0 }
                ))
                ProgramArgumentsEditor(text: Binding(
                    get: { programArguments[message.id] ?? (proposal.arguments ?? []).joined(separator: "\n") },
                    set: { programArguments[message.id] = $0 }
                ))
            }
            if proposal.status == .pending {
                Text(proposal.action == .save ? "Save for later; this does not run the script. Review for secrets before saving."
                     : "Runs locally with your file permissions. No AI tokens are used. Stops after 60 seconds.")
                    .font(SoraTheme.agentCaption).foregroundStyle(.secondary)
                HStack {
                    Button("Dismiss") { session.dismissProgram(messageID: message.id) }
                    if proposal.action == .save {
                        Button("Save to Programs") { session.saveProgram(messageID: message.id) }
                            .disabled(message.commandDirectory == nil || session.programError != nil)
                    } else if let saved {
                        Button("Run Program") {
                            session.runProgram(saved.id,
                                arguments: ProgramArguments.lines(programArguments[message.id] ?? (proposal.arguments ?? []).joined(separator: "\n")),
                                workingDirectory: programDirectories[message.id],
                                proposalMessageID: message.id)
                        }
                    }
                }.disabled(session.isSending || session.isRunningCommand)
            } else {
                Text(proposal.status == .approved ? (proposal.action == .save ? "Saved to Programs" : "Run approved") : "Dismissed")
                    .font(SoraTheme.agentCaption)
            }
            if let error = session.programError { Text(error).foregroundStyle(SoraTheme.danger) }
        }
        .padding(12)
        .background(SoraTheme.accent.opacity(0.06))
    }

    private func webpageCard(_ proposal: AgentWebpageProposal, messageID: UUID) -> some View {
        let pending = proposal.status == .pending
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: SoraTheme.space2) {
                Image(systemName: proposal.status == .failed ? "exclamationmark.triangle" : "link")
                    .foregroundStyle(proposal.status == .failed ? SoraTheme.warning : SoraTheme.accent)
                Text(webpageStatusTitle(proposal))
                    .font(SoraTheme.agentBodySemibold)
                    .lineLimit(2)
                Spacer(minLength: SoraTheme.space2)
                if pending {
                    Button("Dismiss") {
                        session.dismissWebpage(messageID: messageID)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Dismiss webpage")
                    Button("Fetch Webpage") {
                        session.fetchWebpage(messageID: messageID)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SoraTheme.accent)
                    .disabled(session.isSending || session.isRunningCommand)
                    .accessibilityLabel("Fetch webpage")
                } else if proposal.status == .approved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Fetching webpage")
                }
            }
            Text(proposal.url)
                .font(SoraTheme.agentCaption)
                .foregroundStyle(SoraTheme.muted)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(SoraTheme.space3)
        .background(SoraTheme.fillCard, in: RoundedRectangle(cornerRadius: SoraTheme.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: SoraTheme.radiusLarge).stroke(SoraTheme.accent.opacity(0.45), lineWidth: 1))
    }

    private func webpageStatusTitle(_ proposal: AgentWebpageProposal) -> String {
        switch proposal.status {
        case .pending: return "OK if I fetch this webpage?"
        case .approved: return "Fetching webpage"
        case .dismissed: return "Webpage dismissed"
        case .failed: return "Webpage fetch failed"
        }
    }

    private func userPrompt(_ text: String, voice: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(voice ? "/voice" : "/agent")
                .font(SoraTheme.agentMonoSemibold)
                .foregroundStyle(SoraTheme.accent)
                .contextMenu {
                    Button(voice ? "Copy /voice" : "Copy /agent") {
                        PathActions.copy(voice ? "/voice" : "/agent")
                    }
                }
            Text(text)
                .font(SoraTheme.agentMono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button("Copy Prompt") { PathActions.copy(text) }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voice ? "Voice prompt: \(text)" : "Agent prompt: \(text)")
    }

    private func commandCard(_ proposal: AgentCommandProposal, messageID: UUID) -> some View {
        let pending = proposal.status == .pending
        let routine = AgentCommandPermission.allowsAutomatically(proposal.command)
        let message = session.messages.first { $0.id == messageID }
        let executionTitle: String = {
            if let result = message?.commandResult {
                if result.interrupted { return "Command stopped" }
                return result.exitCode == 0 ? "Command finished" : "Command failed (exit \(result.exitCode))"
            }
            return message?.commandState == "failed" ? "Command failed" : "Running command"
        }()
        let stroke = pending
            ? (routine ? SoraTheme.accent.opacity(0.65) : SoraTheme.warning.opacity(0.75))
            : SoraTheme.accent.opacity(0.45)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: SoraTheme.space2) {
                Text(proposal.status == .pending ? "OK if I run this command and read the output?" :
                     proposal.status == .approved ? executionTitle : "Command dismissed")
                    .font(SoraTheme.agentBodySemibold)
                Spacer(minLength: SoraTheme.space2)
                if pending {
                    Button("Dismiss") {
                        session.dismissCommand(messageID: messageID)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Dismiss command")
                    Button("Run Command") {
                        onRunCommand?(messageID)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(routine ? SoraTheme.accent : SoraTheme.warning)
                    .disabled(onRunCommand == nil || session.isSending || session.isRunningCommand)
                    .accessibilityLabel(routine ? "Run command" : "Run command with elevated risk")
                } else if proposal.status == .approved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(executionTitle)
                }
            }
            if pending {
                Text(proposal.summary)
                    .font(SoraTheme.agentCaption)
                    .foregroundStyle(SoraTheme.muted)
                if let directory = session.agentDirectory {
                    Text("In \(StickyPromptBarModel.displayPath(for: directory))")
                        .font(SoraTheme.agentCaption2)
                        .foregroundStyle(.tertiary)
                }
                if !routine {
                    Text("Outside the read-only allowlist — runs with your full file permissions.")
                        .font(SoraTheme.agentCaption2)
                        .foregroundStyle(SoraTheme.warning)
                }
            }
            Text(proposal.command)
                .font(SoraTheme.agentMono)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(SoraTheme.fillCode, in: RoundedRectangle(cornerRadius: SoraTheme.radiusMedium))
                .contextMenu {
                    Button("Copy Command") { PathActions.copy(proposal.command) }
                }
                .accessibilityLabel("Command: \(proposal.command)")
        }
        .padding(SoraTheme.space3)
        .background(SoraTheme.fillCard, in: RoundedRectangle(cornerRadius: SoraTheme.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: SoraTheme.radiusLarge).stroke(stroke, lineWidth: 1))
    }
}

/// Spinner beside its label. `ProgressView("…")` stacks the two vertically on
/// macOS, which reads as a floating spinner above orphaned text.
struct InlineProgressLabel: View {
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SoraTheme.space2) {
            ProgressView()
                .controlSize(.small)
                // Baseline alignment ignores the spinner, so nudge it onto the
                // text's optical center.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(title)
                .font(SoraTheme.agentCaption)
                .foregroundStyle(SoraTheme.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// Compact status-bar control for switching agent approval policy.
private struct AgentPermissionModeMenu: View {
    @Binding var mode: AgentPermissionMode

    var body: some View {
        Menu {
            ForEach(AgentPermissionMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    if option == mode {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: SoraTheme.space1) {
                Image(systemName: mode.systemImage)
                Text(mode.title)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help(mode.statusHelp)
        .accessibilityLabel("Agent permissions: \(mode.title)")
    }
}

/// Setup list matching the three ChatGPT-style approval modes.
struct AgentPermissionModePicker: View {
    @Binding var mode: AgentPermissionMode

    var body: some View {
        VStack(alignment: .leading, spacing: SoraTheme.space2) {
            Text("How should agent actions be approved?")
                .font(SoraTheme.agentBodySemibold)
            ForEach(AgentPermissionMode.allCases) { option in
                let selected = option == mode
                let emphasis = option == .fullAccess ? SoraTheme.warning : SoraTheme.accent
                Button {
                    mode = option
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: SoraTheme.chromeSize, weight: .semibold))
                            .foregroundStyle(selected ? emphasis : SoraTheme.muted)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(SoraTheme.agentBodySemibold)
                                .foregroundStyle(selected ? emphasis : SoraTheme.text)
                            Text(option.detail)
                                .font(SoraTheme.agentCaption)
                                .foregroundStyle(SoraTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: SoraTheme.space2)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: SoraTheme.chromeCaptionSize, weight: .bold))
                                .foregroundStyle(emphasis)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: SoraTheme.radiusMedium, style: .continuous)
                            .strokeBorder(
                                selected ? emphasis.opacity(0.85) : SoraTheme.hairline,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(SoraChromeButtonStyle(cornerRadius: SoraTheme.radiusMedium))
                .accessibilityLabel("\(option.title). \(option.detail)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}


private struct AgentProgramsView: View {
    @ObservedObject var session: AskSession
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var arguments = ""
    @State private var workingDirectory: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Programs").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Save a workflow once. Run it again without AI tokens.").foregroundStyle(.secondary)
            TextField("Search programs", text: $search).textFieldStyle(.roundedBorder)
            if let error = session.programError {
                Text(error).foregroundStyle(SoraTheme.danger)
                Button("Reload catalog") { session.reloadPrograms() }
                Button("Restore catalog backup") { session.restoreProgramsBackup() }
            }
            if session.programs.isEmpty {
                Text("No saved programs yet. After refining a task with Agent, choose Save Workflow as Program from the conversation menu, or ask Agent to save it.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 20) {
                    List(selection: $selectedID) {
                        ForEach(session.programs.filter { search.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(search) }) { program in
                            Text(program.name).tag(program.id)
                        }
                    }.frame(width: 190)
                    if let program = session.programs.first(where: { $0.id == selectedID }) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(program.name).font(.headline)
                            Text(program.summary)
                            ProgramDirectoryPicker(directory: Binding(
                                get: { workingDirectory ?? program.directory },
                                set: { workingDirectory = $0 }
                            ))
                            Text("zsh script · Your file permissions · 60-second limit").font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                Text(program.script).font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ProgramArgumentsEditor(text: $arguments)
                            HStack {
                                Button("Remove from Catalog") { session.removeProgram(program.id) }
                                Spacer()
                                Button("Run Program") {
                                    session.runProgram(program.id, arguments: ProgramArguments.lines(arguments), workingDirectory: workingDirectory)
                                    dismiss()
                                }.buttonStyle(.borderedProminent)
                            }.disabled(session.isSending || session.isRunningCommand || session.programError != nil)
                        }
                    } else {
                        Text("Select a program to review its script and run it.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(24).frame(width: 760, height: 620)
        .onChange(of: selectedID) { _ in arguments = ""; workingDirectory = nil }
    }
}


private struct ProgramArgumentsEditor: View {
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arguments").font(.caption.bold())
            TextField("Paste a URL or other input", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityLabel("Program arguments")
            Text("One argument per line, in script order. Keep spaces as-is; no quotes needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}


private struct ProgramDirectoryPicker: View {
    @Binding var directory: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Working folder: " + directory).font(.caption).textSelection(.enabled)
            Button("Choose Working Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Use Folder"
                if panel.runModal() == .OK, let url = panel.url { directory = url.path }
            }
            Text("Changes the folder for this run; the saved program stays in your catalog.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
