@preconcurrency import AVFAudio
import AudioCommon
import Foundation
import FoundationModels

enum MeetingCaptureState: Equatable {
    case idle
    case recording
    case processing
    case complete
    case error(String)
}

@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var state: MeetingCaptureState = .idle
    @Published private(set) var liveTranscript = ""
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var systemAudioStatus = "System audio ready"
    @Published private(set) var lastWarning: String?
    @Published private(set) var latestRecord: MeetingRecord?

    let store = MeetingStore()

    private let speechEngine: ASREngineRouter
    private let permissions: PermissionManager
    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioTap(excludeCurrentProcess: true)
    private let summarizer = MeetingSummarizer()
    private let translator = OnDeviceTranslator()
    private let recovery = RecoveryStore.shared

    private var microphoneSession: (any TranscriptionSession)?
    private var systemSession: (any TranscriptionSession)?
    private var systemWriter: LockedAudioFileWriter?
    private var microphonePartial = ""
    private var systemPartial = ""
    private var microphoneURL: URL?
    private var systemURL: URL?
    private var startedAt: Date?
    private var elapsedTask: Task<Void, Never>?

    init(speechEngine: ASREngineRouter, permissions: PermissionManager) {
        self.speechEngine = speechEngine
        self.permissions = permissions
    }

    func start(localeIdentifier: String, preferExtendedLanguages: Bool) async {
        guard state != .recording, state != .processing else { return }
        guard await permissions.requestMicrophone() else {
            state = .error(AirScribeError.microphonePermissionDenied.localizedDescription)
            return
        }

        resetCaptureState()
        do {
            let locale = Locale(identifier: localeIdentifier)
            let microphoneSession = try await speechEngine.makeSession(
                locale: locale,
                context: "Meeting transcript. Preserve names, decisions, dates, and action items.",
                preferExtendedLanguages: preferExtendedLanguages
            ) { [weak self] text in
                Task { @MainActor in
                    self?.microphonePartial = text
                    self?.refreshLiveTranscript()
                }
            }
            let systemSession = try await speechEngine.makeSession(
                locale: locale,
                context: "Meeting transcript. Preserve names, decisions, dates, and action items.",
                preferExtendedLanguages: preferExtendedLanguages
            ) { [weak self] text in
                Task { @MainActor in
                    self?.systemPartial = text
                    self?.refreshLiveTranscript()
                }
            }
            self.microphoneSession = microphoneSession
            self.systemSession = systemSession

            let microphoneURL = try store.newAudioURL(source: .you)
            let systemURL = try store.newAudioURL(source: .computer)
            self.microphoneURL = microphoneURL
            self.systemURL = systemURL
            let writer = try LockedAudioFileWriter(url: systemURL, format: systemSession.requiredAudioFormat)
            systemWriter = writer

            try microphone.start(
                targetFormat: microphoneSession.requiredAudioFormat,
                recordingURL: microphoneURL,
                onBuffer: { microphoneSession.append($0) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.microphoneLevel = level }
                }
            )

            do {
                try systemAudio.start(targetSampleRate: Int(systemSession.requiredAudioFormat.sampleRate.rounded())) { [weak self] samples in
                    guard let self,
                          let buffer = Self.makeBuffer(samples: samples, format: systemSession.requiredAudioFormat) else { return }
                    writer.write(buffer)
                    systemSession.append(buffer)
                    Task { @MainActor in
                        self.systemAudioStatus = self.systemAudio.nonSilentFrames > 0
                            ? "Capturing Mac audio"
                            : "Waiting for Mac audio"
                    }
                }
                systemAudioStatus = "Waiting for Mac audio"
            } catch {
                systemAudioStatus = "System audio unavailable — microphone-only recording"
                await systemSession.cancel()
                self.systemSession = nil
                systemWriter = nil
                try? FileManager.default.removeItem(at: systemURL)
                self.systemURL = nil
            }

            startedAt = Date()
            recovery.mark(
                .meeting,
                audioPaths: [microphoneURL.path, self.systemURL?.path].compactMap { $0 }
            )
            state = .recording
            startElapsedTimer()
        } catch {
            _ = stopCaptureHardware()
            let microphoneSession = self.microphoneSession
            let systemSession = self.systemSession
            self.microphoneSession = nil
            self.systemSession = nil
            await microphoneSession?.cancel()
            await systemSession?.cancel()
            removeUnfinishedFiles()
            recovery.complete()
            state = .error(error.localizedDescription)
        }
    }

    func stop(localeIdentifier: String, outputLanguageMode: OutputLanguageMode) async {
        guard state == .recording else { return }
        state = .processing
        elapsedTask?.cancel()
        elapsedTask = nil
        let audioRecordingError = stopCaptureHardware()
        if audioRecordingError != nil {
            removeUnfinishedFiles()
        }

        let microphoneSession = self.microphoneSession
        let systemSession = self.systemSession
        self.microphoneSession = nil
        self.systemSession = nil

        do {
            async let microphoneResult = finish(microphoneSession)
            async let systemResult = finish(systemSession)
            var (microphoneCapture, systemCapture) = try await (microphoneResult, systemResult)
            var microphoneText = microphoneCapture.text
            var systemText = systemCapture.text
            if outputLanguageMode == .english {
                if !microphoneText.isEmpty {
                    microphoneText = (try? await translator.translateToEnglish(microphoneText)) ?? microphoneText
                }
                if !systemText.isEmpty {
                    systemText = (try? await translator.translateToEnglish(systemText)) ?? systemText
                }
            }
            let duration = max(Date().timeIntervalSince(startedAt ?? Date()), 0)
            microphoneCapture = MeetingTranscriptionResult(
                text: microphoneText,
                timings: microphoneCapture.timings,
                duration: microphoneCapture.duration
            )
            systemCapture = MeetingTranscriptionResult(
                text: systemText,
                timings: systemCapture.timings,
                duration: systemCapture.duration
            )
            let segments = (
                MeetingSegmenter.segments(
                    text: systemCapture.text,
                    speaker: .computer,
                    timings: systemCapture.timings,
                    duration: systemCapture.duration ?? duration
                )
                + MeetingSegmenter.segments(
                    text: microphoneCapture.text,
                    speaker: .you,
                    timings: microphoneCapture.timings,
                    duration: microphoneCapture.duration ?? duration
                )
            ).sorted {
                if $0.startTime == $1.startTime { return $0.speaker.rawValue < $1.speaker.rawValue }
                return $0.startTime < $1.startTime
            }
            let transcript = segments
                .map { "\($0.speaker.rawValue): \($0.text)" }
                .joined(separator: "\n\n")
            guard !transcript.isEmpty else { throw AirScribeError.emptyTranscription }
            let summary = await summarizer.summarize(transcript)
            let record = MeetingRecord(
                title: defaultTitle(for: startedAt ?? Date()),
                startedAt: startedAt ?? Date(),
                duration: duration,
                localeIdentifier: localeIdentifier,
                transcript: transcript,
                summary: summary,
                segments: segments,
                microphoneAudioPath: microphoneURL?.path,
                systemAudioPath: systemURL?.path
            )
            try store.add(record)
            latestRecord = record
            liveTranscript = transcript
            microphoneURL = nil
            systemURL = nil
            recovery.complete()
            state = .complete
            if let audioRecordingError {
                lastWarning = "The transcript was saved, but meeting audio could not be written: \(audioRecordingError.localizedDescription)"
            }
        } catch {
            removeUnfinishedFiles()
            recovery.complete()
            state = .error(error.localizedDescription)
        }
    }

    func reset() {
        guard state != .recording, state != .processing else { return }
        latestRecord = nil
        liveTranscript = ""
        state = .idle
    }

    func cancel() async {
        elapsedTask?.cancel()
        elapsedTask = nil
        stopCaptureHardware()
        let microphoneSession = self.microphoneSession
        let systemSession = self.systemSession
        self.microphoneSession = nil
        self.systemSession = nil
        async let cancelMicrophone: Void = microphoneSession?.cancel() ?? ()
        async let cancelSystem: Void = systemSession?.cancel() ?? ()
        _ = await (cancelMicrophone, cancelSystem)
        removeUnfinishedFiles()
        recovery.complete()
        resetCaptureState()
        state = .idle
    }

    private func finish(_ session: (any TranscriptionSession)?) async throws -> MeetingTranscriptionResult {
        guard let session else { return .empty }
        let text = try await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingTranscriptionResult(
            text: text,
            timings: session.wordTimings,
            duration: session.capturedAudioDuration
        )
    }

    private func refreshLiveTranscript() {
        liveTranscript = [
            systemPartial.isEmpty ? nil : "Computer: \(systemPartial)",
            microphonePartial.isEmpty ? nil : "You: \(microphonePartial)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    private func resetCaptureState() {
        // Completed meeting audio belongs to its stored record. Clear those
        // references before startup so a later failure cannot delete it.
        microphoneURL = nil
        systemURL = nil
        liveTranscript = ""
        microphonePartial = ""
        systemPartial = ""
        elapsedSeconds = 0
        microphoneLevel = 0
        latestRecord = nil
        systemAudioStatus = "System audio ready"
        lastWarning = nil
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.elapsedSeconds += 1
            }
        }
    }

    @discardableResult
    private func stopCaptureHardware() -> Error? {
        let microphoneError = microphone.stop()
        systemAudio.stop()
        let systemError = systemWriter?.writeError
        systemWriter = nil
        return microphoneError ?? systemError
    }

    private func removeUnfinishedFiles() {
        if let microphoneURL { try? FileManager.default.removeItem(at: microphoneURL) }
        if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
        microphoneURL = nil
        systemURL = nil
    }

    private func defaultTitle(for date: Date) -> String {
        "Meeting — " + date.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated private static func makeBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0 ..< Int(format.channelCount) {
            channels[channel].update(from: samples, count: samples.count)
        }
        return buffer
    }
}

private final class LockedAudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private var storedWriteError: Error?

    var writeError: Error? {
        lock.withLock { storedWriteError }
    }

    init(url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            do {
                try file.write(from: buffer)
            } catch {
                if storedWriteError == nil { storedWriteError = error }
            }
        }
    }
}

private struct MeetingSummarizer {
    func summarize(_ transcript: String) async -> String {
        let model = SystemLanguageModel.default
        if model.isAvailable {
            let session = LanguageModelSession(
                model: model,
                instructions: """
                Summarize this meeting transcript locally. Return concise Markdown with sections for Overview, Decisions, and Action items.
                Do not invent facts, owners, dates, or decisions. Omit a section when the transcript provides none.
                """
            )
            if let response = try? await session.respond(to: transcript) {
                let value = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        let lines = transcript
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(6)
        return lines.map { "- \($0)" }.joined(separator: "\n")
    }
}
