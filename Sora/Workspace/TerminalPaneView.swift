import AppKit
import Combine
import SwiftUI

/// Pairs the Ghostty grid with a sticky prompt footer so scrollback never
/// paints through the input strip. After agent mode, a Warp-style summary
/// strip sits above the prompt so the user can click back into the thread.
final class TerminalPaneView: NSView {
    let surface: GhosttySurfaceView
    let stickyBar = StickyPromptBar()
    private var agentHost: NSHostingView<AskView>!
    private var resumeHost: NSHostingView<AgentResumeStripView>!
    private(set) var isShowingAgent = false
    private var isPaneActive = false
    private weak var ask: AskSession?
    private var askObservation: AnyCancellable?
    let tabID: UUID

    override var isOpaque: Bool { false }

    init(surface: GhosttySurfaceView, ask: AskSession, tabID: UUID) {
        self.surface = surface
        self.ask = ask
        self.tabID = tabID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = SoraTheme.nsClear.cgColor
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
        addSubview(agentHost)
        surface.autoresizingMask = []
        stickyBar.autoresizingMask = []
        resumeHost.autoresizingMask = []
        agentHost.autoresizingMask = []
        surface.attachStickyPromptBar(stickyBar)
        stickyBar.onFocusTerminal = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.surface)
            self.surface.applyStickyBarFocus()
        }
        stickyBar.onAcceptPrediction = { [weak surface] in
            surface?.acceptStickyPrediction()
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
            .sink { [weak self] _ in self?.refreshResumeStrip() }
        refreshResumeStrip()
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
        }
        surface.setActive(active && !isShowingAgent)
    }

    func showAgent() {
        ask?.bindTab(tabID)
        ask?.configureAgent(directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory)
        isShowingAgent = true
        agentHost.isHidden = false
        stickyBar.isHidden = true
        resumeHost.isHidden = true
        surface.isHidden = true
        surface.setActive(false)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func hideAgent() {
        ask?.stop()
        isShowingAgent = false
        agentHost.isHidden = true
        stickyBar.isHidden = false
        surface.isHidden = false
        surface.setActive(isPaneActive)
        refreshResumeStrip()
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(surface)
    }

    func resumeAgentIfAvailable() -> Bool {
        guard ask?.resumeSummary != nil else { return false }
        showAgent()
        return true
    }

    private func refreshResumeStrip() {
        guard isPaneActive, !isShowingAgent, let ask else {
            resumeHost.isHidden = true
            stickyBar.updateAgentResumeHint(false)
            needsLayout = true
            return
        }
        ask.bindTab(tabID)
        guard let summary = ask.resumeSummary else {
            resumeHost.isHidden = true
            stickyBar.updateAgentResumeHint(false)
            needsLayout = true
            return
        }
        resumeHost.rootView = AgentResumeStripView(summary: summary) { [weak self] in
            self?.showAgent()
        }
        resumeHost.isHidden = false
        stickyBar.updateAgentResumeHint(true)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let barH = StickyPromptBar.height
        if isShowingAgent {
            agentHost.frame = bounds
            surface.frame = .zero
            stickyBar.frame = .zero
            resumeHost.frame = .zero
        } else {
            let resumeH = resumeHost.isHidden ? 0 : (ask?.resumeSummary?.height ?? 0)
            stickyBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
            resumeHost.frame = NSRect(x: 0, y: barH, width: bounds.width, height: resumeH)
            surface.frame = NSRect(
                x: 0,
                y: barH + resumeH,
                width: bounds.width,
                height: max(0, bounds.height - barH - resumeH)
            )
            agentHost.frame = bounds
        }
    }
}
