import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var runtime: GhosttyRuntime
    @StateObject private var ask: AskSession
    @StateObject private var workspace: WorkspaceController
    @State private var sidebarVisible = true
    @State private var titlebarHeight: CGFloat = 52
    @State private var trafficLightWidth: CGFloat = 78
    @State private var agentTrigger = 0

    init(runtime: GhosttyRuntime, windowID: UUID) {
        self.runtime = runtime
        _ask = StateObject(wrappedValue: AskSession(backends: AIBackend.live(windowID: windowID)))
        _workspace = StateObject(
            wrappedValue: WorkspaceController(
                runtime: runtime,
                snapshot: runtime.windowStore.snapshot(for: windowID),
                windowID: windowID
            )
        )
    }

    private var sidebarWidth: CGFloat {
        sidebarVisible ? 220 : 0
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                WorkspaceTabBar(
                    workspace: workspace,
                    sidebarVisible: $sidebarVisible,
                    titlebarHeight: titlebarHeight,
                    trafficLightWidth: trafficLightWidth,
                    onAsk: { agentTrigger += 1 }
                )
                .frame(width: 220)

                Rectangle()
                    .fill(SoraTheme.hairline)
                    .frame(width: 1)
            }

            VStack(spacing: 0) {
                TerminalChromeBar(
                    workspace: workspace,
                    sidebarVisible: $sidebarVisible,
                    titlebarHeight: titlebarHeight,
                    trafficLightWidth: trafficLightWidth,
                    onAsk: { agentTrigger += 1 }
                )
                WorkspaceHostRepresentable(workspace: workspace, ask: ask, agentTrigger: agentTrigger)
                    .frame(minWidth: 480, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
            }
        }
        .animation(SoraTheme.motionSidebar, value: sidebarVisible)
        .tint(SoraTheme.accent)
        .background(WindowFrostRepresentable().ignoresSafeArea())
        .background(
            WindowChromeRepresentable(
                sidebarWidth: sidebarWidth,
                titlebarHeight: $titlebarHeight,
                trafficLightWidth: $trafficLightWidth
            )
        )
        .modifier(ClearWindowBackground())
        .modifier(HiddenWindowTitle())
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .focusedSceneObject(workspace)
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
        .focusedSceneValue(\.inlineAskAction, InlineAskAction { agentTrigger += 1 })
        .onAppear {
            workspace.startPersistence()
            for id in runtime.remainingRestoredWindowIDs(excluding: workspace.windowID) {
                openWindow(id: "terminal", value: id)
            }
            runtime.setFocus(NSApp.isActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in ask.stop() }
        .onDisappear {
            workspace.refreshWorkingDirectories()
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminalPreferences.fontSizeDidChange)) { _ in
            workspace.applyFontSizeToAllSurfaces()
        }
    }
}

private struct SidebarVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct InlineAskAction {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}

private struct InlineAskActionKey: FocusedValueKey {
    typealias Value = InlineAskAction
}

extension FocusedValues {
    var sidebarVisible: Binding<Bool>? {
        get { self[SidebarVisibleKey.self] }
        set { self[SidebarVisibleKey.self] = newValue }
    }

    var inlineAskAction: InlineAskAction? {
        get { self[InlineAskActionKey.self] }
        set { self[InlineAskActionKey.self] = newValue }
    }
}

struct SidebarCommands: Commands {
    @FocusedValue(\.sidebarVisible) private var sidebarVisible

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(sidebarVisible?.wrappedValue == false ? "Show Sidebar" : "Hide Sidebar") {
                withAnimation(SoraTheme.motionSidebar) {
                    sidebarVisible?.wrappedValue.toggle()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(sidebarVisible == nil)
        }
    }
}

/// Full-window frost. Corner radius stays 0 so this is not a floating card.
struct WindowFrostRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = SoraTheme.nsGlassTint
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 0
        return effect
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.cornerRadius = 0
    }
}

/// Puts traffic lights on the sidebar and removes the empty titlebar strip.
private struct WindowChromeRepresentable: NSViewRepresentable {
    var sidebarWidth: CGFloat
    @Binding var titlebarHeight: CGFloat
    @Binding var trafficLightWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(titlebarHeight: $titlebarHeight, trafficLightWidth: $trafficLightWidth)
    }

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.sidebarWidth = sidebarWidth
        view.onMetrics = { [coordinator = context.coordinator] height, lights in
            DispatchQueue.main.async {
                if abs(coordinator.titlebarHeight.wrappedValue - height) > 0.5 {
                    coordinator.titlebarHeight.wrappedValue = height
                }
                if abs(coordinator.trafficLightWidth.wrappedValue - lights) > 0.5 {
                    coordinator.trafficLightWidth.wrappedValue = lights
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        context.coordinator.titlebarHeight = $titlebarHeight
        context.coordinator.trafficLightWidth = $trafficLightWidth
        nsView.sidebarWidth = sidebarWidth
        nsView.revealTrafficLights()
    }

    final class Coordinator {
        var titlebarHeight: Binding<CGFloat>
        var trafficLightWidth: Binding<CGFloat>

        init(titlebarHeight: Binding<CGFloat>, trafficLightWidth: Binding<CGFloat>) {
            self.titlebarHeight = titlebarHeight
            self.trafficLightWidth = trafficLightWidth
        }
    }
}

private final class WindowChromeView: NSView {
    var sidebarWidth: CGFloat = 220
    var onMetrics: ((CGFloat, CGFloat) -> Void)?
    private var resizeObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        applyChrome()
        guard let window else { return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyChrome()
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyChrome()
        }
    }

    override func layout() {
        super.layout()
        revealTrafficLights()
    }

    func applyChrome() {
        guard let window else { return }
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = SoraTheme.nsWindowFill
        clearHostingSafeArea(in: window.contentView)
        revealTrafficLights()
        publishMetrics()
    }

    fileprivate func revealTrafficLights() {
        guard let window else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            button.isHidden = false
            button.alphaValue = 1
            button.superview?.isHidden = false
            button.superview?.alphaValue = 1
        }
        if let container = titlebarContainer(in: window), let parent = container.superview {
            container.isHidden = false
            container.alphaValue = 1
            if parent.subviews.last !== container {
                parent.addSubview(container, positioned: .above, relativeTo: nil)
            }
        }
    }

    private func publishMetrics() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let content = window.contentView
        else { return }

        let closeFrame = close.convert(close.bounds, to: content)
        let zoomFrame = zoom.convert(zoom.bounds, to: content)
        let lights = max(zoomFrame.maxX, closeFrame.maxX) + 10
        let height: CGFloat
        if let container = titlebarContainer(in: window), container.bounds.height > 0 {
            height = container.bounds.height
        } else {
            height = max(closeFrame.maxY + 8, 28)
        }
        onMetrics?(max(height, 28), max(lights, 72))
    }

    private func titlebarContainer(in window: NSWindow) -> NSView? {
        guard let close = window.standardWindowButton(.closeButton) else { return nil }
        var view: NSView? = close.superview
        while let current = view {
            if String(describing: type(of: current)).contains("NSTitlebarContainerView") {
                return current
            }
            view = current.superview
        }
        return close.superview?.superview
    }

    private func clearHostingSafeArea(in view: NSView?) {
        guard let view else { return }
        if String(describing: type(of: view)).contains("NSHostingView"),
           view.responds(to: NSSelectorFromString("setSafeAreaRegions:")) {
            view.setValue(SafeAreaRegions(), forKey: "safeAreaRegions")
        }
        view.subviews.forEach { clearHostingSafeArea(in: $0) }
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }
}

private struct ClearWindowBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}

/// Hide the window title without hiding close/minimize/zoom.
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
