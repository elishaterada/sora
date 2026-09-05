import AppKit
import SwiftUI

/// Pairs the Ghostty grid with a sticky prompt footer so scrollback never
/// paints through the input strip.
final class TerminalPaneView: NSView {
    let surface: GhosttySurfaceView
    let stickyBar = StickyPromptBar()
    private var agentHost: NSHostingView<AskView>!
    private(set) var isShowingAgent = false
    private var isPaneActive = false
    private weak var ask: AskSession?

    override var isOpaque: Bool { false }

    init(surface: GhosttySurfaceView, ask: AskSession) {
        self.surface = surface
        self.ask = ask
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = SoraTheme.nsClear.cgColor
        addSubview(surface)
        addSubview(stickyBar)
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
        agentHost.autoresizingMask = []
        surface.attachStickyPromptBar(stickyBar)
        stickyBar.onFocusTerminal = { [weak surface] in
            guard let surface else { return }
            surface.window?.makeFirstResponder(surface)
        }
        stickyBar.onAcceptPrediction = { [weak surface] in
            surface?.acceptStickyPrediction()
        }
        surface.onAgentPrompt = { [weak self, weak ask] question in
            guard let self, let ask else { return }
            showAgent()
            ask.configureAgent(directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory)
            ask.draft = question
            ask.send()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setActive(_ active: Bool) {
        isPaneActive = active
        isHidden = !active
        surface.setActive(active && !isShowingAgent)
    }

    func showAgent() {
        ask?.configureAgent(directory: surface.currentWorkingDirectory() ?? surface.initialWorkingDirectory)
        isShowingAgent = true
        agentHost.isHidden = false
        stickyBar.isHidden = true
        surface.setActive(false)
    }

    func hideAgent() {
        isShowingAgent = false
        agentHost.isHidden = true
        stickyBar.isHidden = false
        surface.setActive(isPaneActive)
    }

    override func layout() {
        super.layout()
        let barH = StickyPromptBar.height
        stickyBar.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: barH
        )
        surface.frame = NSRect(
            x: 0,
            y: barH,
            width: bounds.width,
            height: max(0, bounds.height - barH)
        )
        agentHost.frame = bounds
    }
}
