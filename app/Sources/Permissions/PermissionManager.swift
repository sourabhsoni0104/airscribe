import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    /// True when macOS still lists AirScribe as allowed but no longer trusts it.
    ///
    /// This happens because an unsigned build's Accessibility grant is pinned to
    /// the exact binary. After an update the switch in System Settings still looks
    /// on, yet `AXIsProcessTrusted()` is false. Toggling it does not help; the
    /// entry has to be removed and re-added, or reset.
    @Published private(set) var accessibilityGrantIsStale = false
    let signature = CodeSignatureInfo.current()
    private var monitoringTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let everTrustedKey = "accessibilityWasGrantedPreviously"

    var globalHotkeyGranted: Bool {
        accessibilityGranted
    }

    /// Explains the situation in the words the user needs, or nil when fine.
    var accessibilityAdvice: String? {
        if accessibilityGranted { return signature.permissionWarning }
        if accessibilityGrantIsStale {
            return "macOS still lists AirScribe as allowed, but it no longer trusts this copy, because the app changed since you granted permission. Turning the switch off and on again will not fix it. Select AirScribe in the list, click the minus button to remove it, then add it again. Reset Permission below does the same thing for you."
        }
        return signature.permissionWarning
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    func refresh() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        if microphoneGranted != microphone { microphoneGranted = microphone }
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }

        if accessibility {
            defaults.set(true, forKey: everTrustedKey)
            if accessibilityGrantIsStale { accessibilityGrantIsStale = false }
        } else {
            // Having been trusted before and not now means the recorded grant no
            // longer matches this binary, rather than the user never allowing it.
            let stale = defaults.bool(forKey: everTrustedKey)
            if accessibilityGrantIsStale != stale { accessibilityGrantIsStale = stale }
        }
    }

    /// Clears the stale Accessibility record so macOS will ask again.
    ///
    /// `tccutil` matches on the signing identifier, which is why builds are signed
    /// with the bundle identifier rather than left linker-signed.
    @discardableResult
    func resetAccessibilityPermission() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.airscribe.mac"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", identifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        defaults.set(false, forKey: everTrustedKey)
        accessibilityGrantIsStale = false
        refresh()
        return true
    }

    /// Polls the permission state at an interval matched to what the user is
    /// doing.
    ///
    /// A fixed 500 ms poll ran for the process's whole lifetime whenever access
    /// was never granted, and stopping permanently on the first grant meant a
    /// later revocation went unnoticed until the app was activated. Polling now
    /// backs off once the user is unlikely to be at the Settings pane, and keeps
    /// a slow watchdog running afterwards.
    static let responsivePollInterval: Duration = .milliseconds(500)
    static let backedOffPollInterval: Duration = .seconds(3)
    static let watchdogPollInterval: Duration = .seconds(10)
    static let responsiveWindow: Duration = .seconds(60)

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            let startedAt = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                let interval: Duration
                if self.accessibilityGranted {
                    interval = Self.watchdogPollInterval
                } else if startedAt.duration(to: .now) < Self.responsiveWindow {
                    interval = Self.responsivePollInterval
                } else {
                    interval = Self.backedOffPollInterval
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneGranted = granted
            if !granted { openMicrophoneSettings() }
            return granted
        case .denied, .restricted:
            microphoneGranted = false
            openMicrophoneSettings()
            return false
        @unknown default:
            microphoneGranted = false
            openMicrophoneSettings()
            return false
        }
    }

    func requestAccessibility() -> Bool {
        startMonitoring()
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = granted
        if !granted { openAccessibilitySettings() }
        return granted
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openPrivacyPane(anchor: "Privacy_Microphone")
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { application, _ in
            application?.activate(options: [.activateAllWindows])
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.systempreferences"
            ).first?.activate(options: [.activateAllWindows])
        }
    }
}
