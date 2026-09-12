import AppKit
import Combine
import os

/// Original synthesized switch/case sounds, not recordings of branded keyboards.
enum TypingSound: String, CaseIterable, Identifiable {
    case silentLinear, softTactile, deepThock, creamyPop, crispClack
    case clickySwitch, heavySwitch, hollowCase, metalCase, springSwitch

    static let preferenceKey = "terminal.effects.soundProfile"
    static let defaultSound: Self = .crispClack
    var id: String { rawValue }
    static func resolve(_ value: String) -> Self { Self(rawValue: value) ?? defaultSound }

    var title: String {
        switch self {
        case .silentLinear: return "Silent Linear"
        case .softTactile: return "Soft Tactile"
        case .deepThock: return "Deep Thock"
        case .creamyPop: return "Creamy Pop"
        case .crispClack: return "Crisp Clack"
        case .clickySwitch: return "Clicky Switch"
        case .heavySwitch: return "Heavy Switch"
        case .hollowCase: return "Hollow Case"
        case .metalCase: return "Metal Case"
        case .springSwitch: return "Spring Switch"
        }
    }
    var detail: String {
        switch self {
        case .silentLinear: return "Soft, damped taps with almost no ring."
        case .softTactile: return "A gentle bump followed by a rounded tap."
        case .deepThock: return "Low, weighty knocks with a wooden warmth."
        case .creamyPop: return "Smooth, rounded pops with a soft landing."
        case .crispClack: return "Bright, clean clacks with a quick finish."
        case .clickySwitch: return "Sharp double clicks with a light bottom-out."
        case .heavySwitch: return "Firm, bassy impacts with a pronounced bottom-out."
        case .hollowCase: return "Airy knocks with a hollow case resonance."
        case .metalCase: return "Bright taps with a short metallic ring."
        case .springSwitch: return "Snappy clicks with a playful spring ping."
        }
    }

    private struct Voice {
        var pitch: Double
        var decay: Double
        var body: Double
        var noise: Double
        var smoothing: Double
        var clickDelay: Double
        var click: Double
        var ring: Double
        var duration: Double
    }
    private var voice: Voice {
        switch self {
        case .silentLinear: return Voice(pitch: 310, decay: 130, body: 0.7, noise: 0.2, smoothing: 0.09, clickDelay: 0, click: 0, ring: 0, duration: 0.055)
        case .softTactile: return Voice(pitch: 490, decay: 95, body: 0.65, noise: 0.25, smoothing: 0.20, clickDelay: 0.009, click: 0.18, ring: 0, duration: 0.075)
        case .deepThock: return Voice(pitch: 175, decay: 60, body: 1, noise: 0.14, smoothing: 0.08, clickDelay: 0.004, click: 0.05, ring: 0, duration: 0.12)
        case .creamyPop: return Voice(pitch: 390, decay: 75, body: 0.9, noise: 0.18, smoothing: 0.12, clickDelay: 0.003, click: 0.10, ring: 0, duration: 0.095)
        case .crispClack: return Voice(pitch: 920, decay: 115, body: 0.5, noise: 0.65, smoothing: 0.70, clickDelay: 0.004, click: 0.25, ring: 0, duration: 0.065)
        case .clickySwitch: return Voice(pitch: 1450, decay: 155, body: 0.25, noise: 0.70, smoothing: 0.90, clickDelay: 0.013, click: 0.9, ring: 0, duration: 0.065)
        case .heavySwitch: return Voice(pitch: 245, decay: 55, body: 1, noise: 0.42, smoothing: 0.35, clickDelay: 0.008, click: 0.35, ring: 0, duration: 0.13)
        case .hollowCase: return Voice(pitch: 610, decay: 40, body: 0.85, noise: 0.20, smoothing: 0.22, clickDelay: 0.007, click: 0.12, ring: 0.15, duration: 0.15)
        case .metalCase: return Voice(pitch: 1850, decay: 90, body: 0.45, noise: 0.42, smoothing: 0.65, clickDelay: 0.004, click: 0.25, ring: 0.45, duration: 0.14)
        case .springSwitch: return Voice(pitch: 1150, decay: 85, body: 0.3, noise: 0.45, smoothing: 0.80, clickDelay: 0.011, click: 0.55, ring: 0.8, duration: 0.18)
        }
    }

    func waveData(variant: Int = 0, isReturn: Bool = false) -> Data {
        let v = voice
        let rate = 44100
        let duration = v.duration * (isReturn ? 1.2 : 1)
        let count = Int(duration * Double(rate))
        let variation = Double(abs(variant % 4))
        let pitch = v.pitch * (0.98 + variation * 0.014) * (isReturn ? 0.76 : 1)
        var seed = UInt32(42 + Int(variation) * 7919)
        var filtered = 0.0
        var samples = [Double]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(seed & 65535) / 32768 - 1
            filtered += v.smoothing * (noise - filtered)
            let attack = min(1, t / 0.0007)
            let body = (sin(2 * .pi * pitch * t) + 0.45 * sin(2 * .pi * pitch * 2.37 * t)) * exp(-v.decay * t)
            let transient = filtered * exp(-t * 240)
            let clickTime = t - v.clickDelay
            let click = clickTime >= 0 ? noise * min(1, clickTime / 0.0003) * exp(-clickTime * 480) : 0
            let ring = sin(2 * .pi * (pitch * 3.1 * t - 160 * t * t)) * exp(-t * 40)
            let fade = min(1, Double(count - 1 - index) / 220)
            samples.append(attack * fade * (v.body * body + v.noise * transient + v.click * click + v.ring * ring))
        }
        let peak = samples.reduce(0) { max($0, abs($1)) }
        // Normalize without clipping; the damped profile intentionally stays quieter.
        let gain = (self == .silentLinear ? 0.38 : 0.8) / max(peak, 0.001)
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); word(UInt32(36 + count * 2)); ascii("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate))
        word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        ascii("data"); word(UInt32(count * 2))
        for sample in samples { word(Int16((sample * gain * 32767).rounded())) }
        return data
    }
}

/// Small preloaded voice pool allows natural overlap without a playback backlog.
@MainActor
final class TypingSoundPlayer: ObservableObject {
    @Published private(set) var errorMessage: String?
    private var profile: TypingSound?
    private var taps: [NSSound] = []
    private var returns: [NSSound] = []
    private var nextTap = 0
    private var nextReturn = 0

    func configure(profile: TypingSound, volume: Double) {
        if self.profile != profile {
            stop()
            let taps = (0..<4).compactMap { NSSound(data: profile.waveData(variant: $0)) }
            let returns = (0..<2).compactMap { NSSound(data: profile.waveData(variant: $0, isReturn: true)) }
            guard taps.count == 4, returns.count == 2 else {
                reportFailure("Couldn’t prepare this typing sound. Choose another sound and try again.")
                self.taps = []; self.returns = []; self.profile = nil
                return
            }
            self.taps = taps; self.returns = returns; self.profile = profile
            nextTap = 0; nextReturn = 0; errorMessage = nil
        }
        let level = Float(min(1, max(0, volume.isFinite ? volume : 0.15)))
        for sound in taps + returns { sound.volume = level }
    }

    func play(isReturn: Bool = false) {
        let pool = isReturn ? returns : taps
        guard !pool.isEmpty else { return }
        let index = isReturn ? nextReturn : nextTap
        let sound = pool[index % pool.count]
        if sound.isPlaying { sound.stop() }
        if sound.play() { errorMessage = nil }
        else { reportFailure("Typing sound playback failed. Check your audio output and try again.") }
        if isReturn { nextReturn = (index + 1) % pool.count }
        else { nextTap = (index + 1) % pool.count }
    }

    private func reportFailure(_ message: String) {
        if errorMessage != message {
            Logger(subsystem: "dev.sora.app", category: "TypingSound").error("\(message, privacy: .public)")
        }
        errorMessage = message
    }

    func stop() { for sound in taps + returns { sound.stop() } }
}
