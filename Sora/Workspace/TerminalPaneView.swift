import AppKit
import SwiftUI

/// Pairs the Ghostty grid with a sticky prompt footer so scrollback never
/// paints through the input strip. Agent mode rises from the prompt as a
/// continuation of the same tab — terminal scrollback stays visible above.
final class TerminalPaneView: NSView {
    let surface: GhosttySurfaceView
    let stickyBar = StickyPromptBar()
    private var agentHost: NSHostingView<AskView>!
    private(set) var isShowingAgent = false
    private var isPaneActive = false
    private weak var ask: AskSession?
    private let terminalDim = NSView()

    /// Keep enough terminal peek so entering Ask does not feel like a hard cut.
    private static let minimumTerminalPeek: CGFloat = 120
    private static let agentHeightFraction: CGFloat = 0.62

    override var isOpaque: Bool { false }

    init(surface: GhosttySurfaceView, ask: AskSession) {
        self.surface = surface
        self.ask = ask
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = SoraTheme.nsClear.cgColor
        addSubview(surface)

        terminalDim.wantsLayer = true
        terminalDim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        terminalDim.isHidden = true
        addSubview(terminalDim)

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
        terminalDim.autoresizingMask = []
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
        terminalDim.isHidden = false
        surface.setActive(false)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func hideAgent() {
        isShowingAgent = false
        agentHost.isHidden = true
        stickyBar.isHidden = false
        terminalDim.isHidden = true
        surface.setActive(isPaneActive)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let barH = StickyPromptBar.height
        if isShowingAgent {
            let agentH = min(
                max(280, bounds.height * Self.agentHeightFraction),
                max(280, bounds.height - Self.minimumTerminalPeek)
            )
            let terminalH = max(0, bounds.height - agentH)
            surface.frame = NSRect(x: 0, y: agentH, width: bounds.width, height: terminalH)
            terminalDim.frame = surface.frame
            agentHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: agentH)
            stickyBar.frame = .zero
        } else {
            stickyBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
            surface.frame = NSRect(
                x: 0,
                y: barH,
                width: bounds.width,
                height: max(0, bounds.height - barH)
            )
            terminalDim.frame = surface.frame
            agentHost.frame = bounds
        }
    }
}
