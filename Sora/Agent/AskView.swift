import AppKit
import SwiftUI

struct AskView: View {
    @ObservedObject var session: AskSession
    var inline = false
    var onClose: (() -> Void)?
    var onRunCommand: ((UUID) -> Void)?
    @StateObject private var codexLogin = CodexLogin()
    @State private var showingSetup = false
    @State private var keyDraft = ""
    @State private var streamingScrollTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleMessages: [AIMessage] {
        session.messages.filter { $0.isAgentContinuation != true }
    }

    private var conversationTitle: String? {
        visibleMessages.first(where: { $0.role == .user })?.text
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showingSetup || !session.enabled {
                setup
                Divider().opacity(0.35)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if visibleMessages.isEmpty {
                            emptyState
                        }
                        ForEach(visibleMessages) { message in
                            messageView(message)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, SoraTheme.gridPaddingX)
                    .padding(.vertical, SoraTheme.space3)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.last?.text) { _ in
                    scheduleStreamingScroll(using: proxy)
                }
                .onChange(of: session.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onDisappear {
                    streamingScrollTask?.cancel()
                    streamingScrollTask = nil
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
        .onAppear {
            session.load()
            if !session.enabled { showingSetup = true }
        }
        .onChange(of: session.selectedProvider) { _ in
            keyDraft = ""
            codexLogin.cancel()
            showingSetup = true
        }
        .onDisappear {
            // Do not stop the stream — Escape / hide is a glance, not a cancel.
            codexLogin.cancel()
            keyDraft = ""
        }
    }

    /// Coalesce token-sized changes into a steady visual cadence. This is a
    /// throttle rather than a debounce, so a response that never pauses still
    /// follows the newest content. The scroll target remains the live bottom.
    private func scheduleStreamingScroll(using proxy: ScrollViewProxy) {
        guard streamingScrollTask == nil else { return }
        let shouldReduceMotion = reduceMotion

        streamingScrollTask = Task { @MainActor in
            defer { streamingScrollTask = nil }
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }

            if shouldReduceMotion {
                proxy.scrollTo("bottom", anchor: .bottom)
            } else {
                withAnimation(SoraTheme.motionStreamingScroll) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
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

                if !inline {
                    Button("Clear Conversation") { session.newConversation() }
                        .disabled(session.messages.isEmpty)
                }
                Menu {
                    Button(showingSetup ? "Hide Setup" : "Setup") { showingSetup.toggle() }
                    Button("Clear Conversation") { session.newConversation() }
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
        }
        .padding(.vertical, inline ? SoraTheme.space2 : 28)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: SoraTheme.space2) {
            TextField(inline ? "Ask a follow up…" : "Ask about a command or paste an error…",
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
                if session.isSending || session.isRunningCommand {
                    Button("Stop", systemImage: "stop.fill") { session.stop() }
                } else {
                    Button("Send", systemImage: "arrow.up") { submitComposer() }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(!session.canSend)
                }
            }
        }
        .padding(.horizontal, SoraTheme.gridPaddingX)
        .padding(.top, 10)
        .padding(.bottom, inline ? 6 : SoraTheme.space4)
    }

    private func submitComposer() {
        guard session.canSend else { return }
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
            Picker("Provider", selection: Binding(get: { session.selectedProvider }, set: { session.selectProvider($0) })) {
                ForEach(session.availableProviders) { id in Text(id.name).tag(id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Choose provider")
            Button {
                showingSetup = true
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
            .help("Choose an agent model")
            .accessibilityLabel("Choose model")
            AgentPermissionModeMenu(mode: $session.permissionMode)
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

    private var setup: some View {
        VStack(alignment: .leading, spacing: SoraTheme.space3) {
            Toggle("Enable Agent", isOn: $session.enabled)
            AgentPermissionModePicker(mode: $session.permissionMode)
            if session.selectedProvider == .codex {
                Text("Use the installed Codex CLI with your Codex / ChatGPT sign-in. Sora does not copy login tokens.")
                    .font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
                HStack {
                    Button("Check Sign-In") { codexLogin.connect(signIn: false) }
                    Button("Sign In with ChatGPT") { codexLogin.connect(signIn: true) }
                    if codexLogin.isBusy { Button("Cancel") { codexLogin.cancel() } }
                }
                .disabled(session.isSending)
                Text(codexLogin.status).font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
            } else {
                Text(session.selectedProvider == .openai
                     ? "Use your OpenAI API key. API usage is billed separately from ChatGPT."
                     : "Use your \(session.selectedProvider.name) key. Usage is billed by that service.")
                    .font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
                HStack {
                    SecureField("\(session.selectedProvider.name) key", text: $keyDraft)
                    Button("Save Key") {
                        let value = keyDraft
                        Task { if await session.saveKey(value), keyDraft == value { keyDraft = "" } }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSending || session.isUpdatingKey)
                    Button("Remove Key") { Task { await session.removeKey(); keyDraft = "" } }
                    .disabled(session.isUpdatingKey || session.isSending)
                }
            }
            if session.isUpdatingKey {
                InlineProgressLabel(title: "Waiting for Keychain…")
            }
            TextField(session.selectedProvider == .codex ? "Model ID (blank uses Codex default)" : "Model ID", text: $session.model)
                .font(SoraTheme.agentBody)
                .disabled(session.isSending)
            if let message = session.setupMessage {
                Text(message).font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
            }
            Text("Credentials stay in macOS Keychain. Each provider has its own local conversation. The agent can run approved commands and fetch public HTTPS pages.")
                .font(SoraTheme.agentCaption).foregroundStyle(SoraTheme.muted)
        }
        .textFieldStyle(.roundedBorder)
        .padding(SoraTheme.space4)
    }

    private func streamingEnvelope(_ text: String) -> (prose: String, title: String)? {
        if let prose = AgentCommandProposalParser.proseBeforeEnvelope(in: text) {
            return (prose, "Preparing a command…")
        }
        if let prose = AgentWebpageProposalParser.proseBeforeEnvelope(in: text) {
            return (prose, "Preparing a webpage…")
        }
        return nil
    }

    private func messageView(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: SoraTheme.space2) {
            if message.role == .user {
                userPrompt(message.text)
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
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    InlineProgressLabel(title: pending.title)
                } else {
                    AgentMarkdownText(
                        text: message.text,
                        relativeTo: session.agentDirectory,
                        streaming: message.status == .streaming
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    private func userPrompt(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("/agent")
                .font(SoraTheme.agentMonoSemibold)
                .foregroundStyle(SoraTheme.accent)
                .contextMenu {
                    Button("Copy /agent") { PathActions.copy("/agent") }
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
        .accessibilityLabel("Agent prompt: \(text)")
    }

    private func commandCard(_ proposal: AgentCommandProposal, messageID: UUID) -> some View {
        let pending = proposal.status == .pending
        let routine = AgentCommandPermission.allowsAutomatically(proposal.command)
        let stroke = pending
            ? (routine ? SoraTheme.accent.opacity(0.65) : SoraTheme.warning.opacity(0.75))
            : SoraTheme.accent.opacity(0.45)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: SoraTheme.space2) {
                Text(proposal.status == .pending ? "OK if I run this command and read the output?" :
                     proposal.status == .approved ? "Running command" : "Command dismissed")
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
                        .accessibilityLabel("Running command")
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
private struct AgentPermissionModePicker: View {
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
