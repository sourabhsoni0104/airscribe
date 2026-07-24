import AppKit
import AVFAudio
import SwiftUI

@MainActor
final class MeetingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MeetingWindowController()

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AirScribe Meetings"
            window.minSize = NSSize(width: 760, height: 520)
            window.center()
            window.delegate = self
            window.contentView = NSHostingView(rootView: MeetingView(model: model))
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the transcript window must not stop an active meeting.
        true
    }
}

private struct MeetingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: MeetingCoordinator
    @ObservedObject private var store: MeetingStore
    @State private var selectedRecordID: UUID?
    @State private var microphonePlayer: AVAudioPlayer?
    @State private var systemPlayer: AVAudioPlayer?

    init(model: AppModel) {
        self.model = model
        coordinator = model.meetings
        store = model.meetings.store
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            if let warning = coordinator.lastWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            Divider()
            HSplitView {
                historySidebar
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 310)
                transcriptPane
                    .frame(minWidth: 480)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: coordinator.latestRecord?.id) { _, id in selectedRecordID = id }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meetings").font(.title2.bold())
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if coordinator.state == .recording {
                HStack(spacing: 3) {
                    ForEach(0 ..< 12, id: \.self) { index in
                        Capsule()
                            .fill(.red.opacity(0.82))
                            .frame(width: 3, height: max(4, CGFloat(coordinator.microphoneLevel) * CGFloat(8 + (index * 7) % 18)))
                    }
                }
                Text(duration(coordinator.elapsedSeconds))
                    .font(.body.monospacedDigit().bold())
                Button("Stop", role: .destructive) {
                    Task {
                        await coordinator.stop(
                            localeIdentifier: model.localeIdentifier,
                            outputLanguageMode: model.outputLanguageMode
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if coordinator.state == .processing {
                ProgressView().controlSize(.small)
                Text("Finishing transcript…").foregroundStyle(.secondary)
            } else {
                Button("Start recording") {
                    Task {
                        await coordinator.start(
                            localeIdentifier: model.localeIdentifier,
                            preferExtendedLanguages: model.preferExtendedLanguages,
                            outputLanguageMode: model.outputLanguageMode
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
    }

    private var historySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Past meetings").font(.headline)
                Spacer()
            }
            .padding(14)
            List(selection: $selectedRecordID) {
                ForEach(store.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title).font(.callout.bold()).lineLimit(2)
                        HStack {
                            Text(record.startedAt, style: .date)
                            Text(duration(Int(record.duration)))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(record.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { store.delete(record) }
                    }
                }
            }
            .overlay {
                if store.records.isEmpty {
                    ContentUnavailableView("No meetings", systemImage: "person.2.wave.2", description: Text("Your local meeting transcripts appear here."))
                }
            }
        }
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let record = selectedRecord {
                recordView(record)
            } else {
                liveView
            }
        }
    }

    @ViewBuilder
    private var liveView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(coordinator.systemAudioStatus, systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Audio and text stay on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case let .error(message) = coordinator.state {
                ContentUnavailableView("Meeting capture stopped", systemImage: "exclamationmark.triangle", description: Text(message))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if coordinator.liveTranscript.isEmpty {
                ContentUnavailableView(
                    coordinator.state == .recording ? "Listening" : "Ready to record",
                    systemImage: "waveform.and.mic",
                    description: Text(coordinator.state == .recording ? "Live words will appear here." : "Capture your microphone and the audio playing on your Mac.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(coordinator.liveTranscript)
                        .font(.system(size: 16, design: .rounded))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(22)
    }

    private func recordView(_ record: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.title).font(.title2.bold())
                        Text(record.startedAt.formatted(date: .long, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Replay") { replay(record) }
                    Menu("Export") {
                        ForEach(MeetingExportFormat.allCases) { format in
                            Button(format.rawValue) { store.export(record, format: format) }
                        }
                    }
                    Button("Delete", role: .destructive) {
                        store.delete(record)
                        selectedRecordID = nil
                    }
                }

                Group {
                    Text("Summary").font(.headline)
                    Text(markdown(record.summary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Text("Transcript").font(.headline)
                Text(record.transcript)
                    .font(.system(size: 15, design: .rounded))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
    }

    private var selectedRecord: MeetingRecord? {
        guard let selectedRecordID else { return coordinator.latestRecord }
        return store.records.first { $0.id == selectedRecordID }
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle: "Microphone + Mac audio, fully on-device"
        case .recording: coordinator.systemAudioStatus
        case .processing: "Transcribing and summarizing locally"
        case .complete: "Saved locally"
        case .error: "Needs attention"
        }
    }

    private func replay(_ record: MeetingRecord) {
        if let path = record.microphoneAudioPath {
            microphonePlayer = try? AVAudioPlayer(contentsOf: URL(filePath: path))
        }
        if let path = record.systemAudioPath {
            systemPlayer = try? AVAudioPlayer(contentsOf: URL(filePath: path))
        }
        microphonePlayer?.currentTime = 0
        systemPlayer?.currentTime = 0
        microphonePlayer?.play()
        systemPlayer?.play()
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }
}
