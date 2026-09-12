import AppKit
import SwiftUI
import UserNotifications

struct SoraSettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case terminal = "Terminal", agent = "Agent", voice = "Voice"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .terminal: return "terminal"
            case .agent: return "sparkles"
            case .voice: return "waveform"
            }
        }
    }

    @AppStorage(TerminalPreferences.appearanceKey) private var appearanceName = "dark"
    @ObservedObject var session: AskSession
    @ObservedObject var globalShortcut: GlobalShortcutController
    @ObservedObject var shortcuts: AppShortcutStore
    @State private var selection: Page? = .terminal

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch selection ?? .terminal {
            case .terminal: TerminalSettingsView(globalShortcut: globalShortcut, shortcuts: shortcuts)
            case .agent: AgentSettingsView(session: session)
            case .voice: VoiceSettingsView(session: session)
            }
        }
        .preferredColorScheme(TerminalPreferences.Appearance(rawValue: appearanceName)?.colorScheme)
        .frame(minWidth: 660, minHeight: 460)
        .onReceive(NotificationCenter.default.publisher(for: SoraSettingsOpener.pageNotification)) { note in
            if let page = note.object as? Page { selection = page }
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(title)
    }
}

private struct TerminalSettingsView: View {
    @ObservedObject var globalShortcut: GlobalShortcutController
    @ObservedObject var shortcuts: AppShortcutStore
    @AppStorage(GlobalShortcutController.enabledKey) private var globalShortcutEnabled = false
    @AppStorage("terminal.automaticAgentRouting") private var automaticAgentRouting = true
    @State private var fontSize = TerminalPreferences.fontSize
    @AppStorage(TerminalPreferences.appearanceKey) private var appearance = "dark"
    @AppStorage(TerminalPreferences.fontFamilyKey) private var family = "SF Mono"
    @AppStorage(TerminalPreferences.compactSpacingKey) private var compact = false
    var body: some View {
        SettingsPage(title: "Terminal") {
            Section("Input") {
                Toggle("Automatically send natural-language input to Agent", isOn: $automaticAgentRouting)
                Text("When off, Return runs shell input. Use /agent or \(shortcuts.binding(.openAgent).display) to ask Agent.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Global shortcut") {
                Toggle("Show or hide Sora with ⌃⌥S", isOn: $globalShortcutEnabled)
                    .onChange(of: globalShortcutEnabled) { _ in globalShortcut.refresh() }
                Text("Control–Option–S works from any app while Sora is running. Hiding Sora returns to the app you came from. Windows stay on their original display and Space.")
                    .font(.caption).foregroundStyle(.secondary)
                if globalShortcut.isRegistered { Text("Shortcut ready").font(.caption).foregroundStyle(.secondary) }
                if let error = globalShortcut.errorMessage { Text(error).font(.caption).foregroundStyle(SoraTheme.danger) }
            }
            ShortcutSettingsSection(shortcuts: shortcuts)
            TerminalNotificationSettingsSection()
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(TerminalPreferences.Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }.onChange(of: appearance) { _ in TerminalPreferences.appearanceChanged() }
                Picker("Font", selection: $family) {
                    ForEach(TerminalPreferences.fontFamilies, id: \.self) { Text($0).tag($0) }
                }.onChange(of: family) { _ in TerminalPreferences.appearanceChanged() }
                Toggle("Compact spacing", isOn: $compact)
                    .onChange(of: compact) { _ in TerminalPreferences.appearanceChanged() }
                HStack {
                    Text("Font size")
                    Slider(value: $fontSize,
                           in: TerminalPreferences.minimumFontSize...TerminalPreferences.maximumFontSize,
                           step: 1)
                    Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
                .onChange(of: fontSize) { TerminalPreferences.fontSize = $0 }
                Button("Restore Appearance Defaults") {
                    TerminalPreferences.resetAppearance()
                    fontSize = TerminalPreferences.defaultFontSize
                }
            }
        }
        .onAppear { fontSize = TerminalPreferences.fontSize }
    }
}

private struct TerminalNotificationSettingsSection: View {
    @AppStorage(TerminalPreferences.notificationsEnabledKey) private var enabled = true
    @AppStorage(TerminalPreferences.completionAlertsEnabledKey) private var completionAlerts = true
    @AppStorage(TerminalPreferences.completionAlertThresholdKey) private var completionThreshold = 30.0
    @State private var status = "Checking…"
    @State private var canRequestPermission = false
    @State private var requesting = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Notifications") {
            Toggle("Notify when background terminals need attention", isOn: $enabled)
            Text("CLI agents and other terminal programs can request alerts. The focused terminal stays quiet. Tab attention badges remain available when alerts are off.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Alert when long commands finish", isOn: $completionAlerts).disabled(!enabled)
            Picker("Commands running at least", selection: $completionThreshold) {
                ForEach([5.0, 10, 30, 60, 120, 300], id: \.self) { seconds in
                    Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")").tag(seconds)
                }
            }.disabled(!enabled || !completionAlerts)
            Text("Ordinary commands can trigger these alerts without special escape sequences. Applies to successes and failures in background sessions.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("macOS permission", value: status)
            HStack {
                if canRequestPermission {
                    Button("Allow Notifications…") {
                        requesting = true
                        errorMessage = nil
                        Task { @MainActor in
                            do {
                                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            requesting = false
                            await refreshStatus()
                        }
                    }
                    .disabled(!enabled || requesting)
                }
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
                       !NSWorkspace.shared.open(url) {
                        errorMessage = "Open System Settings → Notifications → Sora to change notification permissions."
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(SoraTheme.danger) }
        }
        .task { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    @MainActor private func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        canRequestPermission = settings.authorizationStatus == .notDetermined
        switch settings.authorizationStatus {
        case .notDetermined: status = "Not requested"
        case .denied: status = "Denied — enable in System Settings"
        case .authorized:
            status = settings.alertSetting == .enabled ? "Allowed" : "Allowed — banners are off"
            errorMessage = nil
        case .provisional:
            status = "Quiet delivery only"
            errorMessage = nil
        case .ephemeral:
            status = "Temporarily allowed"
            errorMessage = nil
        @unknown default: status = "Unknown"
        }
    }
}

private struct AgentSettingsView: View {
    @ObservedObject var session: AskSession
    @StateObject private var codexLogin = CodexLogin()
    @State private var keyDraft = ""

    var body: some View {
        SettingsPage(title: "Agent") {
            Section {
                Toggle("Enable Agent", isOn: $session.enabled)
            } footer: {
                Text("Terminal, completion, and command history continue to work when Agent is off.")
            }
            Section("Provider") {
                Picker("Service", selection: Binding(
                    get: { session.selectedProvider },
                    set: { session.selectProvider($0) }
                )) {
                    ForEach(session.availableProviders) { Text($0.name).tag($0) }
                }
                TextField(session.selectedProvider == .codex ? "Model (blank uses Codex default)" : "Model",
                          text: $session.model)
                    .disabled(session.isSending)
                Text(session.selectedProvider.disclosure).foregroundStyle(.secondary)
            }
            Section("Credentials") {
                if session.selectedProvider == .codex {
                    Text("Uses the installed Codex CLI and your Codex or ChatGPT sign-in. Sora does not copy login tokens.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Check Sign-In") { codexLogin.connect(signIn: false) }
                        Button("Sign In with ChatGPT") { codexLogin.connect(signIn: true) }
                        if codexLogin.isBusy { Button("Cancel") { codexLogin.cancel() } }
                    }
                    Text(codexLogin.status).foregroundStyle(.secondary)
                } else {
                    Text("Usage is billed separately by \(session.selectedProvider.name). Keys stay in macOS Keychain.")
                        .foregroundStyle(.secondary)
                    SecureField("API key", text: $keyDraft)
                    HStack {
                        Button("Save Key") {
                            let value = keyDraft
                            Task { if await session.saveKey(value), keyDraft == value { keyDraft = "" } }
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isUpdatingKey)
                        Button("Remove Key") { Task { await session.removeKey(); keyDraft = "" } }
                            .disabled(session.isUpdatingKey)
                    }
                }
                if session.isUpdatingKey { ProgressView().controlSize(.small) }
                if let message = session.setupMessage { Text(message).foregroundStyle(.secondary) }
                if let error = session.errorMessage { Text(error).foregroundStyle(SoraTheme.danger) }
            }
            Section("Command permissions") {
                AgentPermissionModePicker(mode: $session.permissionMode)
            }
        }
        .onChange(of: session.selectedProvider) { _ in keyDraft = ""; codexLogin.cancel() }
        .onDisappear { codexLogin.cancel(); keyDraft = "" }
    }
}

private struct VoiceSettingsView: View {
    @ObservedObject var session: AskSession
    var body: some View {
        SettingsPage(title: "Voice") {
            Section("Dictation") {
                LabeledContent("Availability", value: "Terminal and Agent")
                Text("Use the microphone beside an input field. Sora inserts editable text and never submits it automatically.")
                    .foregroundStyle(.secondary)
            }
            Section("Realtime conversation") {
                Picker("Voice model", selection: $session.realtimeVoiceModel) {
                    ForEach(RealtimeVoiceModel.supported, id: \.self) { model in
                        Text(model == RealtimeVoiceModel.recommended ? "\(model) — Recommended" : model)
                            .tag(model)
                    }
                }
                LabeledContent("Availability") {
                    Label(
                        session.realtimeVoiceAvailability.isAvailable ? "Ready" : "Unavailable",
                        systemImage: session.realtimeVoiceAvailability.isAvailable
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(session.realtimeVoiceAvailability.isAvailable ? .green : .secondary)
                }
                Text(session.realtimeVoiceAvailability.reason
                     ?? "Start a live spoken conversation from the waveform button in Agent. Voice uses the OpenAI API key saved in Agent Settings.")
                    .foregroundStyle(.secondary)
                Text("Voice conversations can discuss terminal work, but cannot run commands. Send a typed Agent request to use Sora’s normal command review and approval flow.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum SoraSettingsOpener {
    static let pageNotification = Notification.Name("dev.sora.app.settings.page")

    static func open(page: SoraSettingsView.Page? = nil) {
        let settingsMenu = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .first(where: { menu in
                menu.items.contains(where: { item in
                    item.keyEquivalent == "," && item.keyEquivalentModifierMask.contains(.command)
                })
            })
        if let settingsMenu, let settingsIndex = settingsMenu.items.firstIndex(where: { item in
            item.keyEquivalent == "," && item.keyEquivalentModifierMask.contains(.command)
        }) {
            settingsMenu.performActionForItem(at: settingsIndex)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        guard let page else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: pageNotification, object: page)
        }
    }
}
