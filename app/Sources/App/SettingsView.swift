import AppKit
import AVFAudio
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $model.selectedSettingsSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("AirScribe")
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 210)
        } detail: {
            Group {
                switch model.selectedSettingsSection {
                case .general: GeneralSettingsView(model: model)
                case .modes: ModesSettingsView(model: model)
                case .vocabulary: VocabularySettingsView(model: model)
                case .models: ModelSettingsView(model: model)
                case .byok: CloudPolishSettingsView(model: model)
                case .context: ContextSettingsView(model: model)
                case .history: HistorySettingsView(store: model.history)
                case .privacy: PrivacySettingsView(model: model)
                case .app: MaintenanceSettingsView(model: model)
                }
            }
            .navigationTitle(model.selectedSettingsSection.rawValue)
        }
        .frame(width: 820, height: 560)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case modes = "Writing Modes"
    case vocabulary = "Vocabulary"
    case models = "Models & Languages"
    case context = "Context & Assistant"
    case history = "History"
    case byok = "BYOK Polish"
    case privacy = "Privacy"
    case app = "App & Updates"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .modes: "slider.horizontal.3"
        case .vocabulary: "text.book.closed"
        case .models: "cpu"
        case .context: "viewfinder"
        case .history: "clock.arrow.circlepath"
        case .byok: "key"
        case .privacy: "hand.raised"
        case .app: "arrow.triangle.2.circlepath"
        }
    }
}

private struct ContextSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Private context awareness") {
                Toggle("Use active app context", isOn: $model.contextAwarenessEnabled)
                Toggle("Include clipboard text", isOn: $model.clipboardContextEnabled)
                    .disabled(!model.contextAwarenessEnabled)
                Toggle("Include visible screen text (OCR)", isOn: $model.screenContextEnabled)
                    .disabled(!model.contextAwarenessEnabled)
                Text("Off by default. Context is captured only when dictation begins, skipped in secure fields, and processed on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(model.lastContextSummary, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Inline assistant") {
                Toggle("Enable “Hey AirScribe”", isOn: $model.assistantEnabled)
                Text("Only dictation beginning with “AirScribe” or “Hey AirScribe” invokes the assistant. Other questions are inserted as dictated text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Excluded apps") {
                HStack {
                    Text(model.lastExternalApplicationName.isEmpty
                         ? "Use another app, then return here."
                         : "Last used: \(model.lastExternalApplicationName)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Exclude last app") { model.excludeLastApplicationFromContext() }
                        .disabled(model.lastExternalBundleIdentifier.isEmpty)
                }
                List {
                    ForEach(model.excludedContextApps, id: \.self) { bundleIdentifier in
                        Text(bundleIdentifier).font(.callout.monospaced())
                    }
                    .onDelete(perform: model.removeContextExclusions)
                }
                .frame(height: 100)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct CloudPolishSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var apiKey = ""
    @State private var statusMessage = ""

    var body: some View {
        Form {
            Section("Optional cloud polish") {
                Toggle("Send transcript text for BYOK polish", isOn: $model.cloudPolishEnabled)
                    .disabled(!model.cloudKeyConfigured || model.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Off by default. When enabled, only transcript text is sent to the endpoint below; microphone audio is never sent. AirScribe works fully without this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                TextField("HTTPS responses endpoint", text: $model.cloudEndpoint)
                    .textContentType(.URL)
                TextField("API model ID", text: $model.cloudModel)
                SecureField(model.cloudKeyConfigured ? "Replace saved API key" : "API key", text: $apiKey)
                HStack {
                    Button(model.cloudKeyConfigured ? "Replace key" : "Save key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.cloudKeyConfigured {
                        Label("Stored in Keychain", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Button("Delete key", role: .destructive) { deleteKey() }
                    }
                    Spacer()
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.lastCloudError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Privacy boundary") {
                Label("On-device transcription remains the default", systemImage: "desktopcomputer")
                Label("Cloud use is visibly marked in the notch", systemImage: "eye")
                Label("Requests are not stored by AirScribe", systemImage: "externaldrive.badge.xmark")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func saveKey() {
        do {
            try model.saveCloudAPIKey(apiKey)
            apiKey = ""
            statusMessage = "API key saved securely."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try model.deleteCloudAPIKey()
            apiKey = ""
            statusMessage = "API key deleted."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct ModesSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var editingMode: WritingMode = .email
    @State private var mappingMode: WritingMode = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Writing modes").font(.title2.bold())
                Spacer()
                Toggle("Choose by app", isOn: $model.automaticModeSelection)
                    .toggleStyle(.switch)
            }

            Picker("Mode", selection: $editingMode) {
                ForEach(WritingMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text("Tell AirScribe exactly how \(editingMode.rawValue.lowercased()) text should sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: instructionBinding)
                .font(.body)
                .padding(7)
                .frame(height: 92)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                Button("Reset instruction") { model.resetInstruction(for: editingMode) }
                Spacer()
                Text("Applied only after transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App mappings").font(.headline)
                    Text(lastAppDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $mappingMode) {
                    ForEach(WritingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                Button("Map last app") { model.mapLastApplication(to: mappingMode) }
                    .disabled(model.lastExternalBundleIdentifier.isEmpty)
            }

            List {
                ForEach(model.appModeMappings) { mapping in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapping.applicationName)
                            Text(mapping.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Mode", selection: Binding(
                            get: { mapping.mode },
                            set: { model.updateMapping(mapping.bundleIdentifier, mode: $0) }
                        )) {
                            ForEach(WritingMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
                .onDelete(perform: model.removeMappings)
            }
            .frame(minHeight: 90)
            .overlay {
                if model.appModeMappings.isEmpty {
                    ContentUnavailableView("No app mappings", systemImage: "app.badge", description: Text("Use an app, open AirScribe settings, then map the last app."))
                }
            }
        }
        .padding(24)
    }

    private var instructionBinding: Binding<String> {
        Binding(
            get: { model.modeInstructions[editingMode.rawValue] ?? editingMode.enhancementInstruction },
            set: { model.modeInstructions[editingMode.rawValue] = $0 }
        )
    }

    private var lastAppDescription: String {
        guard !model.lastExternalApplicationName.isEmpty else { return "Switch to an app once, then return here." }
        return "Last used: \(model.lastExternalApplicationName)"
    }
}

private struct ModelSettingsView: View {
    @ObservedObject var model: AppModel

    private var manager: ModelManager { model.modelManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("On-device speech model").font(.title2.bold())
            Text("AirScribe automatically downloads its private on-device speech models during onboarding. System transcription stays available while the download completes.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AirScribe Models").font(.headline)
                            Text("Private · on-device").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(manager.state.title).font(.callout).foregroundStyle(.secondary)
                    }
                    if let progress = manager.state.progress {
                        ProgressView(value: progress)
                    }
                    HStack {
                        switch manager.state {
                        case .downloading, .checking, .verifying:
                            Button("Pause") { manager.pauseInstallation() }
                        case .failed, .paused, .idle:
                            Button("Resume download") { manager.retryInstallation() }
                        case .installed:
                            Label("Installed and verified", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button("Show model folder") { manager.revealModelDirectory() }
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("100+ language pack").font(.headline)
                            Text("Automatic language detection and code-switched speech")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.languagePackManager.state.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let progress = model.languagePackManager.state.progress {
                        ProgressView(value: progress)
                    }
                    HStack {
                        switch model.languagePackManager.state {
                        case .notInstalled:
                            Button("Install language pack") { model.languagePackManager.install() }
                        case .installing:
                            Button("Pause") { model.languagePackManager.pause() }
                        case .paused, .failed:
                            Button("Resume") { model.languagePackManager.retry() }
                        case .installed:
                            Toggle("Use for dictation and meetings", isOn: $model.preferExtendedLanguages)
                            Button("Remove", role: .destructive) {
                                model.preferExtendedLanguages = false
                                model.languagePackManager.remove()
                            }
                        }
                        Spacer()
                        Button("Show folder") { model.languagePackManager.reveal() }
                    }
                }
                .padding(6)
            }

            Label("Models run locally. Your audio is never uploaded for transcription.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Default mode", selection: $model.selectedMode) {
                    ForEach(WritingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Language locale (use “auto” for Hindi + English)", text: $model.localeIdentifier)
                Picker("Output", selection: $model.outputLanguageMode) {
                    ForEach(OutputLanguageMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                if model.outputLanguageMode == .romanizedHindi {
                    Text("Keeps Hindi wording and meaning, but writes it in the Latin alphabet. English words remain unchanged. Use the “auto” locale for mixed Hindi and English speech.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Dictation hotkey", selection: $model.dictationHotkey) {
                    ForEach(DictationHotkey.allCases) { hotkey in
                        Text(hotkey.title).tag(hotkey)
                    }
                }
                Text("Hold the selected key for push-to-talk, or double-press it for hands-free listening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cleanup") {
                Toggle("Use on-device intelligence for deeper polish", isOn: $model.useAppleIntelligence)
                Toggle("Wait for polish before inserting", isOn: $model.waitForPolish)
                Text("Deterministic filler removal and punctuation are always enabled. Deeper polish is optional and remains on device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.waitForPolish
                     ? "AirScribe waits, then inserts the final version once."
                     : "AirScribe inserts immediately, then safely replaces untouched text when polish finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct MaintenanceSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch AirScribe at login",
                    isOn: Binding(
                        get: { model.launchAtLogin.isEnabled },
                        set: { model.launchAtLogin.setEnabled($0) }
                    )
                )
                if !model.launchAtLogin.statusMessage.isEmpty {
                    Text(model.launchAtLogin.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                LabeledContent("Automatic checks") {
                    Label(model.updates.isReady ? "On" : "Starting", systemImage: model.updates.isReady ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(model.updates.isReady ? .green : .secondary)
                }
                Text(model.updates.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for Updates…") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.isReady)
            }

            if let session = model.recovery.interruptedSession {
                Section("Recovered recording") {
                    Label(
                        "An interrupted \(session.kind.rawValue) recording from \(session.startedAt.formatted(date: .abbreviated, time: .shortened)) was preserved.",
                        systemImage: "lifepreserver"
                    )
                    HStack {
                        Button("Show recovered audio") { model.recovery.revealRecoveredFiles() }
                        Button("Discard", role: .destructive) { model.recovery.discardRecoveredFiles() }
                    }
                    if let error = model.recovery.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { model.launchAtLogin.refresh() }
    }
}

private struct VocabularySettingsView: View {
    @ObservedObject var model: AppModel
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom vocabulary").font(.title2.bold())
            Text("Add names, products, and industry terms that must keep their exact spelling.")
                .foregroundStyle(.secondary)
            Toggle("Learn vocabulary from my corrections", isOn: $model.learnFromCorrections)
            Text("When you edit text just inserted by AirScribe, stable word corrections are learned locally. Unrelated field changes are ignored.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Add a term", text: $newTerm)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                if !model.learnedCorrections.isEmpty {
                    Section("Learned corrections") {
                        ForEach(model.learnedCorrections.keys.sorted(), id: \.self) { heard in
                            HStack {
                                Text(heard)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                Text(model.learnedCorrections[heard] ?? "")
                                    .fontWeight(.semibold)
                                Spacer()
                                Button {
                                    model.removeLearnedCorrection(heard)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Forget \(heard)")
                            }
                        }
                    }
                }
                Section("Vocabulary") {
                ForEach(model.customVocabulary, id: \.self) { term in
                    Text(term)
                }
                .onDelete(perform: model.removeVocabularyTerms)
                }
            }
            .overlay {
                if model.customVocabulary.isEmpty && model.learnedCorrections.isEmpty {
                    ContentUnavailableView("No custom terms", systemImage: "text.badge.plus", description: Text("Your vocabulary stays on this Mac."))
                }
            }
        }
        .padding(24)
    }

    private func add() {
        model.addVocabularyTerm(newTerm)
        newTerm = ""
    }
}

private struct HistorySettingsView: View {
    @ObservedObject var store: HistoryStore
    @State private var query = ""
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingRecordID: UUID?
    @State private var audioMessage = ""
    private let playbackTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Dictation history", systemImage: "waveform.badge.mic")
                        .font(.title2.bold())
                    Spacer()
                    Text("\(store.records.count) saved")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                Text("Completed dictations and their microphone recordings are saved locally on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !audioMessage.isEmpty {
                    Text(audioMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = store.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)
            .padding(.top)

            HStack {
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Delete all", role: .destructive) {
                    stopPlayback()
                    try? store.deleteAll()
                }
                    .disabled(store.records.isEmpty)
            }
            .padding()

            List(store.search(query)) { record in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(record.mode.rawValue).font(.caption.bold())
                        Text(record.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(record.latencyMilliseconds) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(record.enhancedText).lineLimit(3)
                    HStack {
                        if audioURL(for: record) != nil {
                            Label("Audio saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Button {
                                togglePlayback(record)
                            } label: {
                                Label(
                                    playingRecordID == record.id ? "Stop" : "Play recording",
                                    systemImage: playingRecordID == record.id ? "stop.fill" : "play.fill"
                                )
                            }
                        } else {
                            Label("Audio unavailable", systemImage: "waveform.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.enhancedText, forType: .string) }
                        Button("Export…") { export(record) }
                        Spacer()
                        Text(record.localeIdentifier).font(.caption).foregroundStyle(.secondary)
                        Button("Delete", role: .destructive) {
                            if playingRecordID == record.id { stopPlayback() }
                            store.delete(record)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 5)
            }
            .overlay {
                if store.records.isEmpty {
                    ContentUnavailableView("No dictations yet", systemImage: "waveform", description: Text("Completed dictations will appear here."))
                }
            }
        }
        .onDisappear(perform: stopPlayback)
        .onReceive(playbackTimer) { _ in
            if let audioPlayer,
               playingRecordID != nil,
               !audioPlayer.isPlaying,
               audioPlayer.currentTime > 0 {
                self.audioPlayer = nil
                playingRecordID = nil
            }
        }
    }

    private func export(_ record: DictationRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AirScribe-\(record.id.uuidString.prefix(8)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try record.enhancedText.write(to: url, atomically: true, encoding: .utf8)
            audioMessage = ""
        } catch {
            audioMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func audioURL(for record: DictationRecord) -> URL? {
        guard let path = record.audioPath else { return nil }
        let url = URL(filePath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func togglePlayback(_ record: DictationRecord) {
        if playingRecordID == record.id {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let url = audioURL(for: record) else {
            audioMessage = "The recording file for this dictation is no longer available."
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay(), player.play() else {
                audioMessage = "This recording could not be played."
                return
            }
            audioPlayer = player
            playingRecordID = record.id
            audioMessage = ""
        } catch {
            audioMessage = "This recording could not be played: \(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingRecordID = nil
    }
}

private struct PrivacySettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var permissions: PermissionManager
    @State private var confirmingDeletion = false

    init(model: AppModel) {
        self.model = model
        permissions = model.permissions
    }

    var body: some View {
        Form {
            Section("On-device by default") {
                Label("No account", systemImage: "person.crop.circle.badge.xmark")
                Label("No telemetry", systemImage: "antenna.radiowaves.left.and.right.slash")
                Label("AirScribe Models and cleanup run locally", systemImage: "desktopcomputer")
            }
            Section("Permissions") {
                PermissionRow(title: "Microphone", granted: permissions.microphoneGranted) {
                    Task { _ = await permissions.requestMicrophone() }
                }
                PermissionRow(title: "Control shortcut & text insertion", granted: permissions.accessibilityGranted) {
                    model.requestControlAndInsertionPermission()
                }
                Button("Open Privacy & Security Settings") { permissions.openPrivacySettings() }
            }
            Section("Local data") {
                Text("Deletes dictation history, meeting transcripts and audio, custom vocabulary, API keys, and all downloaded model files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.dataDeletionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Delete Everything on This Mac…", role: .destructive) {
                    confirmingDeletion = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { model.refreshPermissionsAndHotkey() }
        .confirmationDialog(
            "Permanently delete all AirScribe data on this Mac?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await model.deleteAllLocalData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. AirScribe will download its speech models again when needed.")
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: request)
            }
        }
    }
}
