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
    private var agentHost: NSHostingView<AskView>!
    private var resumeHost: NSHostingView<AgentResumeStripView>!
    private(set) var isShowingAgent = false
    private var isPaneActive = false
    private weak var ask: AskSession?
    private var askObservation: AnyCancellable?
    private let voiceInput = VoiceInputController()
    private var dictationObservation: AnyCancellable?
    let tabID: UUID
    /// Publishes the agent thread title for sidebar / chrome labeling.
    var onActivityTitleChange: ((UUID, String?) -> Void)?

    /// Always reserved between sticky bar and surface so Escape never reflows.
    private static let resumeSlotHeight = AgentResumeSummary.primaryRowHeight

    override var isOpaque: Bool { false }

    init(surface: GhosttySurfaceView, ask: AskSession, tabID: UUID) {
        self.surface = surface
        self.ask = ask
        self.tabID = tabID
        super.init(frame: .zero)
        wantsLayer = true
        // The reserved resume strip belongs to the input surface, so it must
        // not expose a contrasting wallpaper gutter when the strip is hidden.
        layer?.backgroundColor = NSColor(srgbRed: 20.0 / 255, green: 22.0 / 255,
                                        blue: 26.0 / 255, alpha: 1).cgColor
        addSubview(surface)
        addSubview(stickyBar)

        resumeHost = NSHostingView(rootView: AgentResumeStripView(
            summary: AgentResumeSummary(title: "", latestFollowUp: nil),
            onResume: {}
        ))
        resumeHost.isHidden = true
        addSubview(resumeHost)

        agentHost = NSHostingView(rootView: AskView(
            session: ask,
            inline: true,
            onClose: { [weak self] in self?.hideAgent() },
            onRunCommand: { [weak ask] messageID in
                guard let ask else { return }
                ask.configureAgent(directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory)
                ask.runCommand(messageID: messageID)
            }
        ))
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
            guard let self, let ask else { return }
            ask.bindTab(self.tabID)
            self.showAgent()
            ask.beginTerminalAgent(
                question: question,
                directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory
            )
        }
        askObservation = ask.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshResumeStrip()
                self?.publishActivityTitleIfActive()
            }
        refreshResumeStrip()
        publishActivityTitleIfActive()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setActive(_ active: Bool) {
        isPaneActive = active
        isHidden = !active
        if active {
            ask?.bindTab(tabID)
            refreshResumeStrip()
            publishActivityTitleIfActive()
        }
        // Keep the surface "active" for metrics even while the overlay is up;
        // input focus still moves to Ask.
        surface.setActive(active && !isShowingAgent)
    }

    func showAgent() {
        ask?.bindTab(tabID)
        ask?.configureAgent(directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory)
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
            guard let self else { return }
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
        onActivityTitleChange?(tabID, ask?.resumeSummary?.title)
    }

    private func refreshResumeStrip() {
        guard isPaneActive, !isShowingAgent else {
            resumeHost.isHidden = true
            stickyBar.updateAgentResumeHint(false)
            needsLayout = true
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
        let barH = stickyBar.preferredHeight
        let resumeSlot = Self.resumeSlotHeight
        // Surface height is always bounds - sticky - resume slot, whether or
        // not a thread is resumable — PTY rows never change on Escape.
        stickyBar.frame = isShowingAgent
            ? .zero
            : NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        resumeHost.frame = isShowingAgent
            ? .zero
            : NSRect(x: 0, y: barH, width: bounds.width, height: resumeSlot)
        surface.frame = isShowingAgent
            ? bounds
            : NSRect(
                x: 0,
                y: barH + resumeSlot,
                width: bounds.width,
                height: max(0, bounds.height - barH - resumeSlot)
            )
        agentHost.frame = bounds
    }
}
