import AppKit
import QuartzCore
import SwiftUI

/// Window-owned decoration. Never consumes events or participates in terminal input.
struct TerminalEffectsRepresentable: NSViewRepresentable {
    @AppStorage("terminal.effects.glow") private var glow = false
    @AppStorage("terminal.effects.shake") private var shake = false
    @AppStorage("terminal.effects.sound") private var sound = false
    @AppStorage("terminal.effects.returnPulse") private var returnPulse = false
    @AppStorage("terminal.effects.volume") private var volume = 0.15

    @AppStorage(TypingImpact.strengthKey) private var impactStrength = TypingImpact.defaultStrength
    @AppStorage(TypingSound.preferenceKey) private var soundProfile = TypingSound.defaultSound.rawValue

    func makeNSView(context: Context) -> TerminalEffectsView { TerminalEffectsView() }
    func updateNSView(_ view: TerminalEffectsView, context: Context) {
        view.configure(glow: glow, shake: shake, sound: sound, returnPulse: returnPulse, volume: volume, soundProfile: TypingSound.resolve(soundProfile), impactStrength: impactStrength)
    }
}

final class TerminalEffectsView: NSView {
    private let ambient = CAGradientLayer()
    private let pulse = CAGradientLayer()
    private var monitor: Any?
    private let impact = TypingImpact()
    private var impactStrength = TypingImpact.defaultStrength
    private var accessibilityObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    private var glow = false, shake = false, sound = false, returnPulse = false
    private let soundPlayer = TypingSoundPlayer()
    private var lastFeedback: TimeInterval = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for gradient in [ambient, pulse] {
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.15, y: 0)
            gradient.endPoint = CGPoint(x: 0.85, y: 0.8)
            gradient.colors = [SoraTheme.nsAccent.withAlphaComponent(0.16).cgColor,
                               SoraTheme.nsAccent.withAlphaComponent(0).cgColor]
            layer?.addSublayer(gradient)
        }
        pulse.opacity = 0
        pulse.startPoint = CGPoint(x: 0.7, y: 1)
        pulse.endPoint = CGPoint(x: 1, y: 0)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self?.impact.stop()
                    self?.pulse.removeAllAnimations()
                }
            }
        }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.window else { return }
                self.impact.stop()
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ambient.frame = bounds
        pulse.frame = bounds
        CATransaction.commit()
    }

    func configure(glow: Bool, shake: Bool, sound: Bool, returnPulse: Bool, volume: Double, soundProfile: TypingSound, impactStrength: Double) {
        let strength = TypingImpact.normalizedStrength(impactStrength)
        if !shake || self.impactStrength != strength { impact.stop() }
        self.impactStrength = strength
        self.glow = glow; self.shake = shake; self.sound = sound; self.returnPulse = returnPulse
        ambient.isHidden = !glow
        if !glow && !returnPulse { pulse.removeAllAnimations() }
        if sound { soundPlayer.configure(profile: soundProfile, volume: volume) }
        else { soundPlayer.stop() }
        refreshMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        impact.stop()
        refreshMonitor()
    }

    private func refreshMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil, glow || shake || sound || returnPulse else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.feedback(for: event)
            return event
        }
    }

    private func feedback(for event: NSEvent) {
        guard let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil,
              TerminalPreferences.isTypingFeedbackEvent(characters: event.characters,
                  modifiers: event.modifierFlags, isRepeat: event.isARepeat),
              var responder = window.firstResponder as? NSView else { return }
        // Exclude search, settings, palettes and other text fields outside a session.
        while !(responder is TerminalPaneView) && !(responder is GhosttySurfaceView) {
            guard let parent = responder.superview else { return }
            responder = parent
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn || now - lastFeedback >= 0.045 else { return }
        lastFeedback = now
        if sound { soundPlayer.play(isReturn: isReturn) }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if glow || (returnPulse && isReturn) {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = returnPulse && isReturn ? 1 : 0.35
            animation.toValue = 0
            animation.duration = returnPulse && isReturn ? 0.5 : 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulse.add(animation, forKey: "typing")
        }
        if shake, NSEvent.pressedMouseButtons == 0, let content = window.contentView {
            impact.strike(view: content, isReturn: isReturn, strength: impactStrength)
        }
    }

}
