import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var permissions: PermissionManager
    @Environment(\.openSettings) private var openSettings

    init(model: AppModel) {
        self.model = model
        permissions = model.permissions
    }

    var body: some View {
        Group {
            Section {
                Label(statusTitle, systemImage: statusSymbol)
                if case .listening = model.phase, !model.partialTranscript.isEmpty {
                    Text(model.partialTranscript)
                        .lineLimit(2)
                }
            }

            Section("Enhancement mode") {
                ForEach(WritingMode.allCases) { mode in
                    Button {
                        model.chooseMode(mode)
                    } label: {
                        if model.selectedMode == mode {
                            Label(mode.rawValue, systemImage: "checkmark")
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                }
            }

            Section {
                Button("Test dictation now") {
                    Task { await model.beginDictation() }
                }
                .disabled(model.phase == .listening || model.phase == .processing)

                if model.phase == .listening {
                    Button("Finish dictation") {
                        Task { await model.endDictation() }
                    }
                }

                Button {
                    model.selectedSettingsSection = .history
                    openSettings()
                } label: {
                    Label(
                        "Dictation history (\(model.history.records.count))…",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }

            Section("Meetings") {
                Button(model.meetings.state == .recording ? "Open live transcript" : "Record a meeting…") {
                    model.showMeetings()
                }
                if model.meetings.state == .recording {
                    Button("Stop meeting") {
                        Task {
                            await model.meetings.stop(
                                localeIdentifier: model.localeIdentifier,
                                outputLanguageMode: model.outputLanguageMode
                            )
                        }
                    }
                }
            }

            Section("On-device model") {
                Label(model.modelManager.state.title, systemImage: modelStatusSymbol)
                if let progress = model.modelManager.state.progress {
                    ProgressView(value: progress)
                }
                switch model.modelManager.state {
                case .downloading, .checking, .verifying:
                    Button("Pause model download") { model.modelManager.pauseInstallation() }
                case .failed, .paused, .idle:
                    Button("Resume model download") { model.modelManager.retryInstallation() }
                case .installed:
                    EmptyView()
                }
            }

            if let session = model.recovery.interruptedSession {
                Section("Recovered recording") {
                    Text("Interrupted \(session.kind.rawValue) audio was preserved.")
                    Button("Show recovered audio") { model.recovery.revealRecoveredFiles() }
                    Button("Discard recovered audio", role: .destructive) {
                        model.recovery.discardRecoveredFiles()
                    }
                    if let error = model.recovery.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }

            if !permissions.accessibilityGranted {
                Section("Setup required") {
                    Button("Allow Control & Text Access…") {
                        model.requestControlAndInsertionPermission()
                    }
                }
            }

            Section {
                Button("Setup & permissions…") { model.showOnboarding() }
                Button("Check for Updates…") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.isReady)
                SettingsLink { Text("Settings…") }
                Button("Quit AirScribe") {
                    // Let the menu finish dispatching the button action before its
                    // backing window disappears during application termination.
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q")
            }
        }
        .onAppear { model.refreshPermissionsAndHotkey() }
    }

    private var statusTitle: String {
        switch model.phase {
        case .idle: "Ready. Hold or double-press \(model.dictationHotkey.title) to dictate"
        case .peek: "Choose a mode, then hold or double-press \(model.dictationHotkey.title)"
        case .listening: "Listening and recording… release \(model.dictationHotkey.title), or press again to stop"
        case .processing: "Transcribing and cleaning…"
        case .done: "Text inserted"
        case .copied: "No text box found, copied to clipboard"
        case let .learned(heard, correction): "Learned “\(heard)” → “\(correction)”"
        case let .error(message): message
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .idle, .peek: "checkmark.circle"
        case .listening: "waveform"
        case .processing: "ellipsis.circle"
        case .done: "checkmark.circle.fill"
        case .copied: "doc.on.clipboard.fill"
        case .learned: "brain.fill"
        case .error: "exclamationmark.triangle"
        }
    }

    private var modelStatusSymbol: String {
        switch model.modelManager.state {
        case .installed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .idle, .checking, .downloading, .verifying: "arrow.down.circle"
        }
    }
}
