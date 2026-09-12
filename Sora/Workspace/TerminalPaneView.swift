import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Pairs the Ghostty grid with a sticky prompt footer. Agent mode is a hybrid
/// overlay: the Metal surface stays visible underneath (never swapped away),
/// and a translucent Ask panel sits on top. A fixed resume slot above the
/// sticky bar keeps the PTY row count stable.
final class TerminalPaneView: NSView {
    let surface: GhosttySurfaceView
    let stickyBar = StickyPromptBar()
    private let historyPopover = CommandHistoryPopoverView()
    private var welcomeHost: NSHostingView<SessionWelcomeView>!
    private var welcomeDismissed = false
    private var agentHost: NSHostingView<AnyView>!
    private var resumeHost: NSHostingView<AgentResumeStripView>!
    private(set) var isShowingAgent = false
    private var isPaneActive = false
    private var publishedTitle: String?
    private weak var ask: AskSession?
    var onAgentBusyChange: ((UUID, Bool) -> Void)? {
        didSet { onAgentBusyChange?(tabID, hasRunningAgent) }
    }
    var hasRunningAgent: Bool { ask?.isSending == true || ask?.isRunningCommand == true }
    private var askObservation: AnyCancellable?
    private let voiceInput = VoiceInputController()
    private var dictationObservation: AnyCancellable?
    let tabID: UUID
    /// Publishes the agent thread title for sidebar / chrome labeling.
    var onActivityTitleChange: ((UUID, String?) -> Void)?

    /// Always reserved between sticky bar and surface so Escape never reflows.
    private static let resumeSlotHeight = AgentResumeSummary.primaryRowHeight

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    init(surface: GhosttySurfaceView, ask: AskSession, tabID: UUID) {
        self.surface = surface
        self.ask = ask
        self.tabID = tabID
        super.init(frame: .zero)
        registerForDraggedTypes(TerminalImageDrop.draggedTypes)
        wantsLayer = true
        // Share the full-window frost, including the reserved resume strip.
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(surface)
        addSubview(stickyBar)
        welcomeDismissed = surface.historyArchiveURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
            || !TerminalPreferences.showsSessionWelcome
        welcomeHost = NSHostingView(rootView: SessionWelcomeView(shortcuts: surface.runtime.shortcuts, onDismiss: { [weak self] in
            TerminalPreferences.showsSessionWelcome = false
            self?.dismissWelcome()
            self?.window?.makeFirstResponder(self?.surface)
        }))
        welcomeHost.sizingOptions = []
        addSubview(welcomeHost)
        surface.onSessionUsed = { [weak self] in self?.dismissWelcome() }

        resumeHost = NSHostingView(rootView: AgentResumeStripView(
            summary: AgentResumeSummary(title: "", latestFollowUp: nil),
            onResume: {}
        ))
        resumeHost.isHidden = true
        addSubview(resumeHost)
        addSubview(surface.blockActions)
        surface.onBlockSelectionChange = { [weak self] in self?.refreshResumeStrip() }
        historyPopover.isHidden = true
        addSubview(historyPopover)
        historyPopover.onChoose = { [weak surface] in surface?.chooseHistoryCommand(at: $0) }
        historyPopover.onDismiss = { [weak surface] in
            guard let surface else { return }
            surface.dismissCommandHistory()
            surface.window?.makeFirstResponder(surface)
        }
        surface.onHistoryChange = { [weak self] in
            guard let self else { return }
            self.historyPopover.update(self.surface.commandHistory)
            self.historyPopover.isHidden = !self.surface.commandHistory.isPresented || self.isShowingAgent
            self.refreshResumeStrip()
        }

        agentHost = NSHostingView(rootView: AnyView(EmptyView()))
        // AppKit owns this overlay frame; SwiftUI must not feed intrinsic size
        // constraints back into the containing terminal layout.
        agentHost.sizingOptions = []
        agentHost.isHidden = true
        agentHost.alphaValue = 0
        addSubview(agentHost)
        surface.autoresizingMask = []
        stickyBar.autoresizingMask = []
        resumeHost.autoresizingMask = []
        agentHost.autoresizingMask = []
        stickyBar.onHeightChange = { [weak self] in self?.needsLayout = true }
        stickyBar.onMoveCursor = { [weak surface] offset in surface?.moveShellCursor(to: offset) }
        surface.attachStickyPromptBar(stickyBar)
        stickyBar.onFocusTerminal = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.surface)
            self.surface.applyStickyBarFocus()
        }
        stickyBar.onAcceptPrediction = { [weak surface] in
            surface?.acceptStickyPrediction()
        }
        stickyBar.onToggleDictation = { [weak self] in
            guard let self else { return }
            if self.voiceInput.isListening {
                self.voiceInput.stop()
            } else {
                self.voiceInput.toggle()
            }
        }
        voiceInput.onFinished = { [weak surface] transcript in
            surface?.insertDictatedText(transcript)
        }
        dictationObservation = voiceInput.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.stickyBar.updateDictation(
                        listening: self.voiceInput.isListening,
                        transcript: self.voiceInput.transcript,
                        error: self.voiceInput.errorMessage
                    )
                }
            }
        surface.onContinueAgent = { [weak self] in
            self?.resumeAgentIfAvailable() ?? false
        }
        surface.onAgentPrompt = { [weak self, weak ask] question in
            guard let self, let ask, surface.allowLocalAgent() else { return }
            ask.bindTab(self.tabID)
            self.showAgent()
            ask.beginTerminalAgent(
                question: question,
                directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory
            )
        }
        surface.onAgentOutput = { [weak self, weak ask] attachment in
            guard let self, let ask, surface.allowLocalAgent() else { return }
            ask.bindTab(self.tabID)
            ask.attachTerminalOutput(attachment)
            self.showAgent(preservingTerminalSelection: true)
        }
        askObservation = ask.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshResumeStrip()
                if let self { self.onAgentBusyChange?(self.tabID, self.hasRunningAgent) }
                self?.publishActivityTitleIfActive()
            }
        refreshResumeStrip()
        publishActivityTitleIfActive()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard surface.surface != nil,
              sender.draggingSourceOperationMask.contains(.copy),
              TerminalImageDrop.canRead(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingEntered(sender) == .copy, let target = surface.surface else { return false }
        if isShowingAgent, let ask {
            let tab = ask.activeTabID
            let provider = ask.selectedProvider
            TerminalImageDrop.receive(sender.draggingPasteboard) { [weak ask] result in
                guard let ask, ask.activeTabID == tab, ask.selectedProvider == provider else { return }
                switch result {
                case .success(let files): ask.attachImages(files)
                case .failure(let error): NSAlert(error: error).runModal()
                }
            }
            return true
        }
        let destination = surface
        TerminalImageDrop.receive(sender.draggingPasteboard, allowsMultiple: !destination.usesBinaryImagePaste) { [weak self, weak destination] result in
            guard let self, let destination, destination.surface == target else { return }
            do {
                let files = try result.get()
                try destination.insertDroppedImages(files)
            } catch {
                let alert = NSAlert(error: error)
                if let window = self.window { alert.beginSheetModal(for: window) }
            }
        }
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func mountAgentContent() {
        guard let ask else { return }
        agentHost.rootView = AnyView(AskView(
            session: ask, inline: true,
            onClose: { [weak self] in self?.hideAgent() },
            onRunCommand: { [weak self, weak ask] messageID in
                guard let self, let ask, self.surface.allowLocalAgent() else { return }
                ask.configureAgent(directory: self.surface.currentWorkingDirectory() ?? self.surface.initialWorkingDirectory)
                ask.runCommand(messageID: messageID)
            }
        ))
    }

    func setActive(_ active: Bool, visible: Bool? = nil) {
        let changed = isPaneActive != active
        isPaneActive = active
        stickyBar.isPaneActive = active
        isHidden = !(visible ?? active)
        if active {
            ask?.bindTab(tabID)
            refreshResumeStrip()
            publishActivityTitleIfActive()
        }
        if changed {
            if active && isShowingAgent { mountAgentContent() }
            else { agentHost.rootView = AnyView(EmptyView()) }
        }
        // Keep the surface "active" for metrics even while the overlay is up;
        // input focus still moves to Ask.
        surface.setActive(active && !isShowingAgent, visible: (visible ?? active) && !isShowingAgent)
    }

    private func dismissWelcome() {
        guard !welcomeDismissed else { return }
        welcomeDismissed = true
        welcomeHost.isHidden = true
        needsLayout = true
    }

    func showAgent(preservingTerminalSelection: Bool = false) {
        guard surface.allowLocalAgent() else { return }
        dismissWelcome()
        surface.dismissCommandHistory()
        if !preservingTerminalSelection { surface.leaveCommandBlocks(focusInput: false) }
        ask?.bindTab(tabID)
        ask?.configureAgent(directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory)
        if !isShowingAgent { mountAgentContent() }
        isShowingAgent = true
        agentHost.isHidden = false
        stickyBar.isHidden = true
        resumeHost.isHidden = true
        // Soft-deactivate input/occlusion without hiding — hybrid overlay dims
        // the live grid under Ask. setActive(false) would set isHidden=true.
        surface.setActive(false)
        surface.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Dim the live grid; do not hide it — hybrid overlay.
            surface.animator().alphaValue = 0.28
            agentHost.animator().alphaValue = 1
        }
    }

    func hideAgent() {
        // Keep the stream alive so Escape is a glance, not a cancel.
        isShowingAgent = false
        surface.isHidden = false
        stickyBar.isHidden = false
        surface.setActive(isPaneActive)
        refreshResumeStrip()
        needsLayout = true
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            agentHost.animator().alphaValue = 0
            surface.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            guard let self, !self.isShowingAgent else { return }
            self.agentHost.rootView = AnyView(EmptyView())
            self.agentHost.isHidden = true
            self.agentHost.alphaValue = 0
            self.window?.makeFirstResponder(self.surface)
            self.surface.reassertTerminalFocus()
        }
    }

    func resumeAgentIfAvailable() -> Bool {
        guard ask?.resumeSummary != nil else { return false }
        showAgent()
        return true
    }

    private func publishActivityTitleIfActive() {
        guard isPaneActive else { return }
        let title = ask?.resumeSummary?.title
        guard title != publishedTitle else { return }
        publishedTitle = title
        onActivityTitleChange?(tabID, title)
    }

    private func refreshResumeStrip() {
        surface.blockActions.isHidden = isShowingAgent || !surface.isBrowsingCommandBlocks
        if (surface.isBrowsingCommandBlocks || surface.commandHistory.isPresented) && !isShowingAgent {
            resumeHost.isHidden = true
            needsLayout = true
            return
        }
        guard isPaneActive, !isShowingAgent else {
            resumeHost.isHidden = true
            stickyBar.updateAgentResumeHint(false)
            return
        }
        ask?.bindTab(tabID)
        if let ask, let summary = ask.resumeSummary {
            resumeHost.rootView = AgentResumeStripView(summary: summary) { [weak self] in
                self?.showAgent()
            }
            stickyBar.updateAgentResumeHint(true)
        } else {
            // Keep the reserved slot occupied so the PTY never gains rows when
            // a thread becomes resumable.
            resumeHost.rootView = AgentResumeStripView(
                summary: AgentResumeSummary(title: "", latestFollowUp: nil),
                onResume: {}
            )
            stickyBar.updateAgentResumeHint(false)
        }
        resumeHost.isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        stickyBar.maximumHeight = max(StickyPromptBar.height, bounds.height * 0.5)
        let barH = min(stickyBar.preferredHeight, stickyBar.maximumHeight)
        let resumeSlot = Self.resumeSlotHeight
        let welcomeHeight: CGFloat = !welcomeDismissed && !isShowingAgent
            && TerminalPreferences.showsSessionWelcome && bounds.height - barH - resumeSlot >= 280
            ? 228 : 0
        welcomeHost.isHidden = welcomeHeight == 0
        welcomeHost.frame = NSRect(x: 0, y: barH + resumeSlot, width: bounds.width, height: welcomeHeight)
        // Surface height is always bounds - sticky - resume slot, whether or
        // not a thread is resumable — PTY rows never change on Escape.
        stickyBar.frame = isShowingAgent
            ? .zero
            : NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        resumeHost.frame = isShowingAgent
            ? .zero
            : NSRect(x: 0, y: barH, width: bounds.width, height: resumeSlot)
        surface.blockActions.frame = resumeHost.frame
        surface.frame = isShowingAgent
            ? bounds
            : NSRect(
                x: 0,
                y: barH + resumeSlot + welcomeHeight,
                width: bounds.width,
                height: max(0, bounds.height - barH - resumeSlot - welcomeHeight)
            )
        historyPopover.frame = NSRect(x: 0, y: barH, width: bounds.width,
                                      height: CommandHistoryLayout.panelHeight(
                                        preferred: historyPopover.preferredHeight, pane: bounds.height, input: barH))
        if agentHost.frame != bounds { agentHost.frame = bounds }
    }
}

/// Native session guidance lives outside the PTY and never enters scrollback.
private struct SessionWelcomeView: View {
    @ObservedObject var shortcuts: AppShortcutStore
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New terminal session", systemImage: "terminal")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Your shell is ready. Start with a command below.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9) {
                shortcut("↑ ↓", "Browse command history")
                shortcut("⇧↵", "Add a new line")
                shortcut(shortcuts.binding(.openAgent).display, "Open Agent")
                shortcut("⌘↵", "Run input as a shell command")
            }
            HStack {
                Spacer(minLength: 0)
                Button("Don’t show again", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: SoraTheme.nsInputBackground))
        .overlay(alignment: .top) { Rectangle().fill(SoraTheme.hairline).frame(height: 1) }
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 60, height: 22)
                .background(SoraTheme.fillSubtle, in: RoundedRectangle(cornerRadius: 4))
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
