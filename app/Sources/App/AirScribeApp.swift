import AppKit
import SwiftUI

@main
struct AirScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.phase == .listening ? "waveform" : "waveform.badge.mic")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
        if !AppModel.shared.onboardingComplete {
            OnboardingWindowController.shared.show(model: AppModel.shared)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.refreshPermissionsAndHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await AppModel.shared.cancelDictation() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "airscribe" && $0.host == "meetings" }) else { return }
        AppModel.shared.showMeetings()
    }
}
