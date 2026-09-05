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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.last?.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }

            if let error = session.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .accessibilityLabel("AI error: \(error)")
            }

            Divider().opacity(0.35)
            composer
            statusBar
        }
        .background(inlineBackground)
        .frame(minWidth: inline ? 0 : 540, minHeight: inline ? 0 : 560)
        .preferredColorScheme(.dark)
        .onAppear {
            session.load()
            if !session.enabled { showingSetup = true }
        }
        .onChange(of: session.selectedProvider) { _ in
            keyDraft = ""
            codexLogin.cancel()
            showingSetup = true
        }
        .onDisappear { session.stop(); codexLogin.cancel(); keyDraft = "" }
    }

    private var inlineBackground: some View {
        ZStack {
            Color.black.opacity(inline ? 0.72 : 0.88)
            if inline {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.35)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            if inline {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
            }
            HStack(spacing: 10) {
                if inline {
                    Button {
                        onClose?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("ESC for terminal")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Return to the terminal session")
                } else {
                    Text("Ask Sora").font(.title2.weight(.semibold))
                }

                Spacer(minLength: 8)

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
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280)
                }

                Spacer(minLength: 8)

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
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("Conversation options")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, inline ? 8 : 14)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(inline ? "New agent conversation" : "What would you like to do?")
                .font(inline ? .callout.weight(.medium) : .title3.weight(.medium))
            Text(inline
                 ? "This thread belongs to the current tab. Escape returns to the same terminal prompt."
                 : "Ask about a command, describe a task, or paste an error you want help understanding.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !inline {
                Button("How do I find the largest files in a folder?") {
                    session.draft = "How do I find the largest files in a folder on macOS?"
                    composerFocused = true
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, inline ? 8 : 28)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(inline ? "Ask a follow up…" : "Ask about a command or paste an error…",
                      text: $session.draft, axis: inline ? .horizontal : .vertical)
                .lineLimit(inline ? 1...3 : 2...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .accessibilityLabel("Question")
                .onSubmit { submitComposer() }
            HStack {
                if !inline {
                    Text(session.selectedProvider.disclosure)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("↵ send")
                        .font(.caption2)
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
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, inline ? 6 : 16)
    }

    private func submitComposer() {
        guard session.canSend else { return }
        session.send()
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
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
            .help("Choose AI provider")
            Button {
                showingSetup = true
            } label: {
                Text(session.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "Choose model"
                      : session.model)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Choose an agent model")
            AgentPermissionModeMenu(mode: $session.permissionMode)
            Spacer(minLength: 0)
            Text(session.selectedProvider.disclosure)
                .lineLimit(1)
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .help("Routine read-only commands run automatically in this directory. Other commands require approval.")
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable AI", isOn: $session.enabled)
            AgentPermissionModePicker(mode: $session.permissionMode)
            if session.selectedProvider == .codex {
                Text("Use the installed Codex CLI with your Codex / ChatGPT sign-in. Sora does not copy login tokens.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Check Sign-In") { codexLogin.connect(signIn: false) }
                    Button("Sign In with ChatGPT") { codexLogin.connect(signIn: true) }
                    if codexLogin.isBusy { Button("Cancel") { codexLogin.cancel() } }
                }
                .disabled(session.isSending)
                Text(codexLogin.status).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(session.selectedProvider == .openai
                     ? "Use your OpenAI API key. API usage is billed separately from ChatGPT."
                     : "Use your \(session.selectedProvider.name) key. Usage is billed by that service.")
                    .font(.caption).foregroundStyle(.secondary)
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
                ProgressView("Waiting for Keychain…").controlSize(.small)
            }
            TextField(session.selectedProvider == .codex ? "Model ID (blank uses Codex default)" : "Model ID", text: $session.model)
                .disabled(session.isSending)
            if let message = session.setupMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Credentials stay in macOS Keychain. Each provider has its own local conversation. The agent can run approved commands and fetch public HTTPS pages.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
    }

    private func messageView(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == .user {
                userPrompt(message.text)
            } else {
                HStack {
                    Text("Sora").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if !message.text.isEmpty {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                if message.text.isEmpty && message.status == .streaming {
                    ProgressView("Thinking…").controlSize(.small)
                } else if message.status == .streaming,
                          AgentCommandProposalParser.isStreamingEnvelope(message.text) {
                    ProgressView("Preparing a command…").controlSize(.small)
                } else if message.status == .streaming,
                          AgentWebpageProposalParser.isStreamingEnvelope(message.text) {
                    ProgressView("Preparing a webpage…").controlSize(.small)
                } else {
                    LinkedText(text: message.text, relativeTo: session.agentDirectory)
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(page.url.absoluteString).font(.caption).textSelection(.enabled)
                        if page.isExcerpt { Text("Excerpt from page").font(.caption).foregroundStyle(.secondary) }
                        Text(page.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
            if let state = message.commandState, state == "stopped" || state == "failed" {
                Text((message.webpageProposal == nil ? "Command " : "Fetch ") + state)
                    .font(.caption).foregroundStyle(.secondary)
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
                ProgressView(
                    message.commandState == "stopped" ? "Stopping…"
                    : message.commandState == "fetching" ? "Fetching webpage…"
                    : "Running command…"
                )
                .controlSize(.small)
            }
            if message.status == .stopped || message.status == .failed {
                Text(message.status == .stopped ? "Stopped — partial answer" : "Answer incomplete")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func webpageCard(_ proposal: AgentWebpageProposal, messageID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: proposal.status == .failed ? "link.badge.plus" : "link")
                Text(webpageStatusTitle(proposal))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if proposal.status == .pending {
                    Button {
                        session.dismissWebpage(messageID: messageID)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    Button {
                        session.fetchWebpage(messageID: messageID)
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isSending || session.isRunningCommand)
                    .help("Fetch Webpage")
                } else if proposal.status == .approved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Text(proposal.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.45), lineWidth: 1))
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
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .contextMenu {
                    Button("Copy /agent") { PathActions.copy("/agent") }
                }
            Text(text)
                .font(.system(.body, design: .monospaced))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(proposal.status == .pending ? "OK if I run this command and read the output?" :
                     proposal.status == .approved ? "Running command" : "Command dismissed")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if proposal.status == .pending {
                    Button {
                        session.dismissCommand(messageID: messageID)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    Button {
                        onRunCommand?(messageID)
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(onRunCommand == nil || session.isSending || session.isRunningCommand)
                    .help("Run Command")
                } else if proposal.status == .approved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if proposal.status == .pending {
                Text(proposal.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                ContextChip(
                    title: proposal.command,
                    help: "Command actions",
                    actions: ContextChipActions.command(proposal.command)
                )
                .font(.system(.body, design: .monospaced))
                .padding(10)
            }
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.65), lineWidth: 1))
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
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                Text(mode.title)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .help("How agent actions are approved")
        .accessibilityLabel("Agent permissions: \(mode.title)")
    }
}

/// Setup list matching the three ChatGPT-style approval modes.
private struct AgentPermissionModePicker: View {
    @Binding var mode: AgentPermissionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How should agent actions be approved?")
                .font(.callout.weight(.semibold))
            ForEach(AgentPermissionMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(option == mode ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(option == mode ? Color.accentColor : .primary)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if option == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(option == mode ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
