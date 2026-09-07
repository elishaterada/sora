import Sparkle

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var policy = UpdateCheckPolicy()

    override init() {
        super.init()
        _ = controller
    }

    func checkAtLaunch() {
        guard policy.beginLaunchProbe() else { return }

        #if !DEBUG
        controller.updater.checkForUpdateInformation()
        #else
        _ = policy.finishLaunchProbe()
        #endif
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        policy.recordFoundUpdate()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard policy.finishLaunchProbe() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.controller.checkForUpdates(nil)
        }
    }
}
