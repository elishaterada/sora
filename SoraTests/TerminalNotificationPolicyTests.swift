import XCTest

final class TerminalNotificationPolicyTests: XCTestCase {
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
