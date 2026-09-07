struct UpdateCheckPolicy {
    private(set) var hasCheckedThisLaunch = false
    private var launchProbeInProgress = false
    private var launchProbeFoundUpdate = false

    mutating func beginLaunchProbe() -> Bool {
        guard !hasCheckedThisLaunch else { return false }
        hasCheckedThisLaunch = true
        launchProbeInProgress = true
        launchProbeFoundUpdate = false
        return true
    }

    mutating func recordFoundUpdate() {
        guard launchProbeInProgress else { return }
        launchProbeFoundUpdate = true
    }

    mutating func finishLaunchProbe() -> Bool {
        guard launchProbeInProgress else { return false }
        let shouldPresentUpdate = launchProbeFoundUpdate
        launchProbeInProgress = false
        launchProbeFoundUpdate = false
        return shouldPresentUpdate
    }
}
