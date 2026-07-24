import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage = ""

    init() { refresh() }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            statusMessage = isEnabled ? "AirScribe will open when you log in." : "Launch at login is off."
        } catch {
            refresh()
            statusMessage = error.localizedDescription
        }
    }

    func disableForDataReset() {
        guard SMAppService.mainApp.status != .notRegistered else {
            refresh()
            return
        }
        do {
            try SMAppService.mainApp.unregister()
            refresh()
            statusMessage = "Launch at login is off."
        } catch {
            refresh()
            statusMessage = error.localizedDescription
        }
    }
}
