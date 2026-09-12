import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SkinSettingsView: View {
    @ObservedObject var library: SkinLibrary
    @ObservedObject var session: AskSession
    @State private var removing: TerminalSkin?
    @State private var source = ""
    @State private var start = "0"
    @State private var end = "15"
    @State private var showsAgent = false
    private var config: SkinConfiguration { library.configuration }
    private func binding<T>(_ key: WritableKeyPath<SkinConfiguration, T>) -> Binding<T> {
        Binding(get: { config[keyPath: key] }, set: { value in library.update { $0[keyPath: key] = value } })
    }
    var body: some View {
        Form {
            Section {
                Toggle("Use custom skin", isOn: binding(\.enabled)).disabled(config.skins.isEmpty)
                Text("Your photos and videos, softened behind the terminal. Sora keeps its own copy of every skin.")
                    .font(.caption).foregroundStyle(.secondary)
                if let skin = config.selected {
                    ZStack(alignment: .bottomLeading) {
                        SkinBackground(library: library, preview: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("~/Projects  % swift build").foregroundStyle(SoraTheme.accent)
                            Text("Build complete. Ready when you are.")
                        }.font(.system(.callout, design: .monospaced)).padding(20)
                    }
                    .frame(height: 150).background(SoraTheme.pandaBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Skin preview: \(skin.name)")
                }
                HStack {
                    Button("Add Photo or Video…", action: importFiles)
                    if library.importing { ProgressView().controlSize(.small); Text("Copying and preparing…").font(.caption) }
                }.disabled(library.importing || library.loadFailed)
                if let error = library.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Show Skin Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
                }
            }
            if !config.skins.isEmpty {
                Section("Your skins") {
                    ForEach(config.skins) { skin in
                        HStack(spacing: 12) {
                            if let image = NSImage(contentsOf: library.posterURL(for: skin)) {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 42).clipped().cornerRadius(5)
                            }
                            Button { library.select(skin.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(skin.name).lineLimit(1)
                                    Text(skin.kind == .video ? (skin.hasAudio ? "Video · includes audio" : "Video") : "Photo")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("Use \(skin.name)")
                            if skin.id == config.selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Selected") }
                            Button(role: .destructive) { removing = skin } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(skin.name)")
                        }
                    }
                }
                Section("Finish") {
                    HStack {
                        Text("Readability")
                        Slider(value: binding(\.readability), in: 0.25...0.95, step: 0.05)
                            .accessibilityLabel("Readability")
                        Text("\(Int((config.readability * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44)
                    }
                    Text("Increase to soften distractions and give text a calmer backdrop. The tint follows your light or dark theme.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Extend photos with softened edges", isOn: binding(\.extendImage))
                    Text("Keeps the whole photo visible and fills extra space with a blurred extension of its colors.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Subtle perspective with pointer movement", isOn: binding(\.perspective))
                    Text("Reduce Motion pauses video and perspective. Reduce Transparency uses a solid background.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let skin = config.selected, skin.kind == .video, skin.hasAudio {
                        Toggle("Play this video's sound", isOn: Binding(get: { !skin.muted }, set: { value in
                            library.update { state in
                                if let index = state.skins.firstIndex(where: { $0.id == skin.id }) { state.skins[index].muted = !value }
                            }
                        }))
                        Text("Sound plays only in the active terminal window. New videos start muted.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Change skin", selection: binding(\.rotationSeconds)) {
                        Text("Manually").tag(0.0)
                        Text("Every minute").tag(60.0)
                        Text("Every 5 minutes").tag(300.0)
                        Text("Every 15 minutes").tag(900.0)
                        Text("Every 30 minutes").tag(1800.0)
                        Text("Every hour").tag(3600.0)
                        Text("Every day").tag(86400.0)
                    }.onChange(of: config.rotationSeconds) { _ in library.update { $0.rotationAnchor = Date() } }
                    Text("Cycles through your library in order while Sora is running. All terminal windows use the same skin.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Make a clip with Agent") {
                Text("Paste a video link and choose up to five minutes to keep. Agent can prepare the clip and add it to your skins, with approval for downloads and changes.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Video link", text: $source, prompt: Text("https://www.youtube.com/watch?v=…"))
                HStack {
                    TextField("Start (seconds)", text: $start)
                    TextField("End (seconds)", text: $end)
                }
                if let error = SkinClipRequest.validationError(source: source, start: start, end: end), !source.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Prepare with Agent…") { prepareClip() }
                    .disabled(clipPrompt == nil || !session.enabled || session.isSending || session.isRunningCommand || !session.draft.isEmpty || session.goal?.isUnfinished == true)
                if !session.enabled { Text("Enable Agent in Agent settings to use this option. Local imports work without AI.").font(.caption).foregroundStyle(.secondary) }
                if !session.draft.isEmpty || session.goal?.isUnfinished == true {
                    Text("Finish the current Agent task or draft before preparing another clip.").font(.caption).foregroundStyle(.secondary)
                }
                if !session.messages.isEmpty || !session.draft.isEmpty {
                    Button("Open Clip Agent") { showsAgent = true }
                }
            }
        }
        .formStyle(.grouped).navigationTitle("Skins")
        .alert("Remove skin?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { library.remove(removing) }; removing = nil }
        } message: { Text("Sora's copy will be deleted. Your original file is unaffected.") }
        .sheet(isPresented: $showsAgent) { AskView(session: session, onClose: { showsAgent = false }, onRunCommand: { session.runCommand(messageID: $0) }).frame(width: 740, height: 640) }
    }
    private var clipPrompt: String? { SkinClipRequest.prompt(source: source, start: start, end: end) }
    private func prepareClip() {
        guard let prompt = clipPrompt else { return }
        session.skinLibrary = library
        session.requiresCommandApproval = true
        session.configureAgent(directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        session.draft = prompt
        showsAgent = true
    }
    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "Add to Skins"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls {
                    do { try await library.add(url) }
                    catch { library.errorMessage = error.localizedDescription; break }
                }
            }
        }
    }
}
