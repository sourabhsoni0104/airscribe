import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    private var monitoringTask: Task<Void, Never>?

    var globalHotkeyGranted: Bool {
        accessibilityGranted
    }

    init() {
        refresh()
    }

    func refresh() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        if microphoneGranted != microphone { microphoneGranted = microphone }
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                if self?.accessibilityGranted == true {
                    self?.monitoringTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
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
