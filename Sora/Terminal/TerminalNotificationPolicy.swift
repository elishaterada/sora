import Foundation

struct TerminalNotificationPolicy {
    static func shouldDeliver(enabled: Bool = true, appActive: Bool, keyWindow: Bool, firstResponder: Bool,
                              lastDelivery: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard !(appActive && keyWindow && firstResponder) else { return false }
        return now.timeIntervalSince(lastDelivery ?? .distantPast) >= 5
    }
}
