import AppKit
import QuartzCore

/// Presentation-only recoil: the window frame and the view's model transform never move.
@MainActor
final class TypingImpact {
    static let strengthKey = "terminal.effects.impactStrength"
    static let defaultStrength = 1.0
    static let strengthRange = 0.25...2.0
    static func normalizedStrength(_ value: Double) -> Double {
        value.isFinite ? min(strengthRange.upperBound, max(strengthRange.lowerBound, value)) : defaultStrength
    }

    static let animationKey = "sora.typingImpact"
    private weak var target: CALayer?
    struct Pattern {
        let rotation: Double
        let x: Double
        let y: Double
        let frequency: Double
        let damping: Double
    }
    // Distinct directional blows: twists, diagonal kicks and vertical recoil.
    static let patterns: [Pattern] = [
        .init(rotation: 1, x: 0.8, y: 0, frequency: 1, damping: 1),
        .init(rotation: -0.8, x: -0.5, y: 0.7, frequency: 1.12, damping: 1.05),
        .init(rotation: 0.55, x: 0, y: -1.2, frequency: 0.88, damping: 0.9),
        .init(rotation: -1.15, x: 0.9, y: -0.5, frequency: 0.95, damping: 1.1),
        .init(rotation: 0.85, x: -1.1, y: -0.3, frequency: 1.18, damping: 0.95),
        .init(rotation: -0.5, x: 0.2, y: 1.1, frequency: 0.82, damping: 0.85),
        .init(rotation: 1.1, x: 0.6, y: 0.9, frequency: 1.06, damping: 1.15),
        .init(rotation: -0.95, x: -0.9, y: 0.4, frequency: 0.9, damping: 1)
    ]
    struct Pose: Equatable, Hashable {
        var angle: Double = 0
        var x: Double = 0
        var y: Double = 0
    }
    struct PatternCycle {
        private var remaining: [Int] = []
        private var previous: Int?
        mutating func next() -> Int {
            if remaining.isEmpty {
                remaining = Array(patterns.indices).shuffled()
                if remaining.last == previous { remaining.swapAt(0, remaining.count - 1) }
            }
            let next = remaining.removeLast()
            previous = next
            return next
        }
    }
    private var cycle = PatternCycle()
    private var returnPriorityUntil: TimeInterval = 0

    func strike(view: NSView, isReturn: Bool, strength: Double = defaultStrength, now: TimeInterval = CACurrentMediaTime()) {
        guard isReturn || now >= returnPriorityUntil else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        if target !== layer { stop(); target = layer }
        if isReturn { returnPriorityUntil = now + 0.24 }
        let initial = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        let angle = atan2(Double(initial.m12), Double(initial.m11))
        let duration = isReturn ? 0.65 : 0.36
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let visibleCenter = center.applying(CATransform3DGetAffineTransform(initial))
        let pose = Pose(angle: angle, x: visibleCenter.x - center.x, y: visibleCenter.y - center.y)
        let values = Self.poses(isReturn: isReturn, patternIndex: cycle.next(), initial: pose, strength: strength)
        let animation = CAKeyframeAnimation(keyPath: "sublayerTransform")
        animation.values = values.map { NSValue(caTransform3D: Self.transform(pose: $0, center: center)) }
        animation.duration = duration
        animation.calculationMode = .linear
        // Replaces the previous impulse from its visible pose. No tasks, frame writes,
        // accumulated model transforms, or delayed restoration callbacks.
        layer.add(animation, forKey: Self.animationKey)
    }

    func stop() {
        target?.removeAnimation(forKey: Self.animationKey)
        target = nil
        returnPriorityUntil = 0
    }

    static func poses(isReturn: Bool, patternIndex: Int, initial: Pose = Pose(), strength: Double = defaultStrength) -> [Pose] {
        let strength = normalizedStrength(strength)
        let pattern = patterns[patternIndex]
        let duration = isReturn ? 0.65 : 0.36
        let count = isReturn ? 40 : 24
        let amplitude = (isReturn ? 3.4 : 0.65) * Double.pi / 180 * strength
        let damping = (isReturn ? 9.5 : 16.0) * pattern.damping
        let frequency = (isReturn ? 34.0 : 42.0) * pattern.frequency
        var samples: [Pose] = (0...count).map { index in
            let time = Double(index) / Double(count) * duration
            let decay = exp(-damping * time)
            let value = initial.angle * decay * cos(frequency * time)
                + pattern.rotation * amplitude * decay * sin(frequency * time)
            // Bound rapid retriggering even when keys arrive during a return impact.
            let limit = (isReturn ? 2.8 : 2.4) * Double.pi / 180 * strength
            let recoil = (isReturn ? 6.0 : 1.5) * strength * decay * sin(frequency * 0.8 * time)
            let inherited = decay * cos(frequency * 0.8 * time)
            let distanceLimit = (isReturn ? 8.0 : 6.0) * strength
            return Pose(angle: min(limit, max(-limit, value)),
                        x: min(distanceLimit, max(-distanceLimit, initial.x * inherited + pattern.x * recoil)),
                        y: min(distanceLimit, max(-distanceLimit, initial.y * inherited + pattern.y * recoil)))
        }
        samples[0] = initial
        samples[samples.count - 1] = Pose()
        return samples
    }

    static func transform(pose: Pose, center: CGPoint) -> CATransform3D {
        CATransform3DMakeAffineTransform(
            CGAffineTransform(translationX: center.x + pose.x, y: center.y + pose.y)
                .rotated(by: pose.angle)
                .translatedBy(x: -center.x, y: -center.y)
        )
    }
}
