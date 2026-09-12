import AppKit
import AVFoundation
import SwiftUI

struct SkinBackground: NSViewRepresentable {
    @ObservedObject var library: SkinLibrary
    var preview = false
    func makeNSView(context: Context) -> SkinBackgroundView { SkinBackgroundView() }
    func updateNSView(_ view: SkinBackgroundView, context: Context) { view.configure(library: library, preview: preview) }
    static func dismantleNSView(_ view: SkinBackgroundView, coordinator: ()) { view.stop() }
}

/// Owns playback and pointer tracking independently of terminal rendering and SwiftUI.
final class SkinBackgroundView: NSView {
    private let imageLayer = CALayer()
    private let extensionLayer = CALayer()
    private let mediaLayer = CALayer()
    private let videoLayer = AVPlayerLayer()
    private let veil = CALayer()
    private let glass: NSView
    private var preview = false
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observations: [NSObjectProtocol] = []
    private var failureObservation: NSKeyValueObservation?
    private var monitor: Any?
    private var selectedID: UUID?
    private var config = SkinConfiguration()
    private weak var library: SkinLibrary?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .regular; effect.cornerRadius = 0
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow; effect.blendingMode = .withinWindow; effect.state = .active
            glass = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(mediaLayer)
        mediaLayer.addSublayer(extensionLayer)
        mediaLayer.addSublayer(imageLayer)
        mediaLayer.addSublayer(videoLayer)
        imageLayer.contentsGravity = .resizeAspect
        extensionLayer.contentsGravity = .resizeAspectFill
        extensionLayer.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 35])].compactMap { $0 }
        videoLayer.videoGravity = .resizeAspectFill
        addSubview(glass)
        layer?.addSublayer(veil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPlayback() }
            })
        }
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshAppearance(); self?.refreshPlayback() } })
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        for observer in observations {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
    func stop() {
        player?.pause(); looper?.disableLooping(); player?.removeAllItems()
        player = nil; looper = nil; videoLayer.player = nil; failureObservation = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func configure(library: SkinLibrary, preview: Bool = false) {
        self.preview = preview
        self.library = library
        config = library.configuration
        let skin = config.enabled ? config.selected : nil
        if selectedID != skin?.id {
            stop(); selectedID = skin?.id
            imageLayer.contents = nil; extensionLayer.contents = nil
            if let skin {
                if let image = NSImage(contentsOf: library.posterURL(for: skin)) {
                    var rect = CGRect(origin: .zero, size: image.size)
                    let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    imageLayer.contents = cg; extensionLayer.contents = cg
                } else {
                    Task { @MainActor [weak library] in library?.errorMessage = "The stored skin preview is missing. Import the file again." }
                }
                if skin.kind == .video {
                    let item = AVPlayerItem(url: library.url(for: skin))
                    let queue = AVQueuePlayer()
                    queue.isMuted = true
                    player = queue; videoLayer.player = queue
                    looper = AVPlayerLooper(player: queue, templateItem: item)
                    failureObservation = looper?.observe(\.status, options: [.initial, .new]) { [weak library] loop, _ in
                        guard loop.status == .failed else { return }
                        let message = loop.error?.localizedDescription ?? "The video could not be played."
                        Task { @MainActor in library?.errorMessage = message }
                    }
                }
            }
        }
        isHidden = skin == nil
        refreshAppearance(); refreshPlayback(); needsLayout = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshPlayback() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }
    private func refreshAppearance() {
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        mediaLayer.isHidden = solid
        glass.isHidden = solid
        glass.alphaValue = 0.22
        let color = TerminalPreferences.isLight ? NSColor.white : NSColor.black
        veil.backgroundColor = color.withAlphaComponent(solid ? 1 : config.readability).cgColor
        imageLayer.contentsGravity = config.extendImage ? .resizeAspect : .resizeAspectFill
        extensionLayer.isHidden = !config.extendImage
        videoLayer.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        mediaLayer.transform = CATransform3DIdentity
    }
    private func refreshPlayback() {
        let visible = window != nil && window?.occlusionState.contains(.visible) == true && NSApp.isActive && !isHidden
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        player?.isMuted = preview || config.selected?.muted != false || window?.isKeyWindow != true || !visible || reduced
        if visible && !reduced { player?.play() } else { player?.pause() }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        mediaLayer.transform = CATransform3DIdentity
        if visible && config.perspective && !reduced {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window, self.window?.isKeyWindow == true else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let x = max(-1, min(1, point.x / max(1, self.bounds.width) * 2 - 1))
                let y = max(-1, min(1, point.y / max(1, self.bounds.height) * 2 - 1))
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.mediaLayer.transform = CATransform3DTranslate(CATransform3DMakeScale(1.04, 1.04, 1), x * 8, y * 8, 0)
                CATransaction.commit()
                return event
            }
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mediaLayer.frame = bounds
        imageLayer.frame = bounds; videoLayer.frame = bounds
        extensionLayer.frame = bounds.insetBy(dx: -45, dy: -45)
        glass.frame = bounds; veil.frame = bounds
        CATransaction.commit()
    }
}
