import Foundation

struct TerminalNotificationPolicy {
    static func completionThreshold(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? min(3600, max(1, seconds)) : 30
    }

    static func shouldNotifyCompletion(enabled: Bool, durationNanos: UInt64, threshold: TimeInterval) -> Bool {
        enabled && Double(durationNanos) / 1_000_000_000 >= completionThreshold(threshold)
    }

    static func shouldDeliver(enabled: Bool = true, appActive: Bool, keyWindow: Bool, firstResponder: Bool,
                              lastDelivery: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard !(appActive && keyWindow && firstResponder) else { return false }
        return now.timeIntervalSince(lastDelivery ?? .distantPast) >= 5
    }
}
