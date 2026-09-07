import XCTest

final class UpdateCheckPolicyTests: XCTestCase {
    func testLaunchCheckCanOnlyBeClaimedOnce() {
        var policy = UpdateCheckPolicy()

        XCTAssertTrue(policy.beginLaunchProbe())
        XCTAssertFalse(policy.beginLaunchProbe())
        XCTAssertTrue(policy.hasCheckedThisLaunch)
    }

    func testFinishedProbeOnlyPresentsWhenAnUpdateWasFound() {
        var noUpdate = UpdateCheckPolicy()
        XCTAssertTrue(noUpdate.beginLaunchProbe())
        XCTAssertFalse(noUpdate.finishLaunchProbe())

        var updateFound = UpdateCheckPolicy()
        XCTAssertTrue(updateFound.beginLaunchProbe())
        updateFound.recordFoundUpdate()
        XCTAssertTrue(updateFound.finishLaunchProbe())
        XCTAssertFalse(updateFound.finishLaunchProbe())
    }

    func testFoundCallbackOutsideAProbeIsIgnored() {
        var policy = UpdateCheckPolicy()

        policy.recordFoundUpdate()
        XCTAssertFalse(policy.finishLaunchProbe())
    }
}
