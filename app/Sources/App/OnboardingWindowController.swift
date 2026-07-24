import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = OnboardingView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to AirScribe"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var permissions: PermissionManager
    @ObservedObject private var modelManager: ModelManager

    init(model: AppModel) {
        self.model = model
        permissions = model.permissions
        modelManager = model.modelManager
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.06, blue: 0.16), Color(red: 0.16, green: 0.07, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AirScribe").font(.largeTitle.bold())
                        Text("Private voice-to-text, ready anywhere on your Mac.")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    SetupCard(
                        number: "1",
                        title: "Microphone",
                        detail: "Capture your voice. Audio remains on this Mac.",
                        granted: permissions.microphoneGranted,
                        actionTitle: "Allow microphone"
                    ) {
                        Task { _ = await permissions.requestMicrophone() }
                    }
                    SetupCard(
                        number: "2",
                        title: "Control & insertion",
                        detail: "One macOS permission enables your dictation shortcut and places text in other apps.",
                        granted: permissions.accessibilityGranted,
                        actionTitle: permissions.accessibilityGrantIsStale
                            ? "Fix Accessibility"
                            : "Allow Accessibility"
                    ) {
                        // A stale grant cannot be repaired by asking again: macOS
                        // already lists the app as allowed. Clear the record first.
                        if permissions.accessibilityGrantIsStale {
                            permissions.resetAccessibilityPermission()
                        }
                        model.requestControlAndInsertionPermission()
                    }
                    SetupCard(
                        number: "3",
                        title: "On-device models",
                        detail: "Prepare private transcription locally. Downloads can continue in the background.",
                        granted: modelManager.state == .installed,
                        actionTitle: "Prepare models"
                    ) {
                        modelManager.startAutomaticInstallation()
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Label("AirScribe Models · on-device", systemImage: "cpu")
                                .font(.headline)
                            Spacer()
                            Text(modelManager.state.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let progress = modelManager.state.progress {
                            ProgressView(value: progress)
                        }
                        HStack {
                            Text("Downloads automatically. Apple on-device transcription is usable while it finishes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            switch modelManager.state {
                            case .downloading, .checking, .verifying:
                                Button("Pause") { modelManager.pauseInstallation() }
                            case .failed, .paused, .idle:
                                Button("Resume") { modelManager.retryInstallation() }
                            case .installed:
                                Label("Verified", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(4)
                }

                HStack {
                    Label("No account. No transcription API. No telemetry.", systemImage: "lock.shield.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") {
                        model.refreshPermissionsAndHotkey()
                    }
                    Button("Finish setup") { model.finishOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(34)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.refreshPermissionsAndHotkey()
            modelManager.startAutomaticInstallation()
        }
    }
}

private struct SetupCard: View {
    let number: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(number)
                    .font(.caption.bold())
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.1), in: Circle())
                Spacer()
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
            }
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Button(actionTitle, action: action)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            granted ? .green.opacity(0.055) : .white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(granted ? .green.opacity(0.4) : .white.opacity(0.1))
        }
    }
}
