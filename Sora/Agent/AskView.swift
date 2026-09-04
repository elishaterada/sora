import AppKit
import SwiftUI

struct AskView: View {
    @ObservedObject var session: AskSession
    @State private var showingSetup = false
    @State private var keyDraft = ""
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
                TextField("Ask about a command or paste an error…", text: $session.draft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .accessibilityLabel("Question")
                HStack {
                    Text("Only this conversation is sent to OpenAI.")
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
        .onAppear {
            session.load()
            if !session.enabled { showingSetup = true }
        }
        .onDisappear { session.stop(); keyDraft = "" }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable AI", isOn: $session.enabled)
            Text("Use your own OpenAI API key. API usage is billed separately from ChatGPT.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField("OpenAI API key", text: $keyDraft)
                Button("Save Key") {
                    if session.saveKey(keyDraft) { keyDraft = "" }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSending)
                Button("Remove Key") { session.removeKey(); keyDraft = "" }
            }
            TextField("Model ID", text: $session.model)
                .disabled(session.isSending)
            if let message = session.setupMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Your key stays in macOS Keychain. Conversations are saved on this Mac. Sora does not run AI-generated commands.")
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
            if message.status == .stopped || message.status == .failed {
                Text(message.status == .stopped ? "Stopped — partial answer" : "Answer incomplete")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
