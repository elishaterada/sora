import XCTest

final class TerminalNotificationPolicyTests: XCTestCase {
    func testOrdinaryCompletionUsesConfiguredDurationAndToggle() {
        XCTAssertFalse(TerminalNotificationPolicy.shouldNotifyCompletion(enabled: true, durationNanos: 29_999_999_999, threshold: 30))
        XCTAssertTrue(TerminalNotificationPolicy.shouldNotifyCompletion(enabled: true, durationNanos: 30_000_000_000, threshold: 30))
        XCTAssertFalse(TerminalNotificationPolicy.shouldNotifyCompletion(enabled: false, durationNanos: UInt64.max, threshold: 30))
        XCTAssertTrue(TerminalNotificationPolicy.shouldNotifyCompletion(enabled: true, durationNanos: 5_000_000_000, threshold: 5))
        XCTAssertEqual(TerminalNotificationPolicy.completionThreshold(.nan), 30)
        XCTAssertEqual(TerminalNotificationPolicy.completionThreshold(.infinity), 30)
        XCTAssertEqual(TerminalNotificationPolicy.completionThreshold(-5), 1)
        XCTAssertEqual(TerminalNotificationPolicy.completionThreshold(10_000), 3600)
    }

    func testFocusedTerminalIsQuietButOtherTabsAndWindowsNotify() {
        let now = Date()
        XCTAssertFalse(TerminalNotificationPolicy.shouldDeliver(appActive: true, keyWindow: true, firstResponder: true, lastDelivery: nil, now: now))
        XCTAssertTrue(TerminalNotificationPolicy.shouldDeliver(appActive: false, keyWindow: true, firstResponder: true, lastDelivery: nil, now: now))
        XCTAssertTrue(TerminalNotificationPolicy.shouldDeliver(appActive: true, keyWindow: false, firstResponder: true, lastDelivery: nil, now: now))
        XCTAssertTrue(TerminalNotificationPolicy.shouldDeliver(appActive: true, keyWindow: true, firstResponder: false, lastDelivery: nil, now: now))
    }

    func testDisabledNotificationsNeverDeliverEvenInBackground() {
        XCTAssertFalse(TerminalNotificationPolicy.shouldDeliver(enabled: false, appActive: false, keyWindow: false, firstResponder: false, lastDelivery: nil, now: Date()))
    }

    func testRepeatedSignalsAreThrottled() {
        let now = Date()
        XCTAssertFalse(TerminalNotificationPolicy.shouldDeliver(appActive: false, keyWindow: false, firstResponder: false, lastDelivery: now.addingTimeInterval(-4.9), now: now))
        XCTAssertTrue(TerminalNotificationPolicy.shouldDeliver(appActive: false, keyWindow: false, firstResponder: false, lastDelivery: now.addingTimeInterval(-5), now: now))
    }
}
