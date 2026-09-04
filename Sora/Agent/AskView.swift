import AppKit
import SwiftUI

struct AskView: View {
    @ObservedObject var session: AskSession
    @StateObject private var codexLogin = CodexLogin()
    @State private var showingSetup = false
    @State private var keyDraft = ""
    @State private var showingWebpage = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask Sora").font(.title2.weight(.semibold))
                    Text("Command help, one question at a time.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Conversation") { session.newConversation() }
                    .disabled(session.messages.isEmpty)
                Button("Setup", systemImage: "slider.horizontal.3") { showingSetup.toggle() }
            }
            .padding(20)
            HStack {
                Picker("Provider", selection: Binding(get: { session.selectedProvider }, set: { session.selectProvider($0) })) {
                    ForEach(session.availableProviders) { id in Text(id.name).tag(id) }
                }
                .frame(maxWidth: 350)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            Divider()

            if showingSetup || !session.enabled {
                setup
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if session.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("What would you like to do?").font(.title3.weight(.medium))
                                Text("Ask about a command, describe a task, or paste an error you want help understanding.")
                                    .foregroundStyle(.secondary)
                                Button("How do I find the largest files in a folder?") {
                                    session.draft = "How do I find the largest files in a folder on macOS?"
                                    composerFocused = true
                                }
                                .buttonStyle(.link)
                            }
                            .padding(.vertical, 28)
                        }
                        ForEach(session.messages) { message in
                            messageView(message)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.last?.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }

            if let error = session.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .accessibilityLabel("AI error: \(error)")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(session.webpage == nil ? "Attach webpage" : "Review webpage", systemImage: "link") {
                        showingWebpage = true
                    }
                    .disabled(session.isSending)
                    if let page = session.webpage {
                        Text(page.url.host ?? page.title).font(.caption).lineLimit(1)
                        Spacer()
                        Button("Remove", systemImage: "xmark") { session.attachWebpage(nil) }
                            .disabled(session.isSending)
                    }
                }
                TextField("Ask about a command or paste an error…", text: $session.draft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .accessibilityLabel("Question")
                HStack {
                    Text(session.selectedProvider.disclosure)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session.isSending {
                        Button("Stop", systemImage: "stop.fill") { session.stop() }
                    } else {
                        Button("Send", systemImage: "arrow.up") { session.send() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!session.canSend)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 540, minHeight: 560)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingWebpage) {
            WebpageAttachmentView(page: session.webpage, providerName: session.selectedProvider.name) {
                session.attachWebpage($0)
            }
        }
        .onAppear {
            session.load()
            if !session.enabled { showingSetup = true }
        }
        .onChange(of: session.selectedProvider) { _ in
            keyDraft = ""
            codexLogin.cancel()
            showingSetup = true
            showingWebpage = false
        }
        .onChange(of: session.enabled) { enabled in
            if !enabled { showingWebpage = false }
        }
        .onDisappear { session.stop(); codexLogin.cancel(); keyDraft = ""; showingWebpage = false }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable AI", isOn: $session.enabled)
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
                        if session.saveKey(keyDraft) { keyDraft = "" }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSending)
                    Button("Remove Key") { session.removeKey(); keyDraft = "" }
                }
            }
            TextField(session.selectedProvider == .codex ? "Model ID (blank uses Codex default)" : "Model ID", text: $session.model)
                .disabled(session.isSending)
            if let message = session.setupMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Credentials stay in macOS Keychain. Each provider has its own local conversation. Ask does not run commands.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
    }

    private func messageView(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == .user ? "You" : "Sora").font(.callout.weight(.semibold))
                Spacer()
                if message.role == .assistant, !message.text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if message.text.isEmpty && message.status == .streaming {
                ProgressView("Thinking…").controlSize(.small)
            } else {
                Text(message.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if message.status == .stopped || message.status == .failed {
                Text(message.status == .stopped ? "Stopped — partial answer" : "Answer incomplete")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
