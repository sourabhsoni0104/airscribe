import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var statusMessage = "Update service is starting…"

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func start() {
        guard !isReady else { return }
        controller.startUpdater()
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        isReady = true
        statusMessage = "Automatic update checks are on."
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
