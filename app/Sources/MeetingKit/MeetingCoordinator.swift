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

enum MeetingCaptureError: LocalizedError {
    case insufficientStorage(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case let .insufficientStorage(required, available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "A meeting recording needs \(formatter.string(fromByteCount: required)) free; \(formatter.string(fromByteCount: available)) is available."
        }
    }
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
    private var startedAtInstant: ContinuousClock.Instant?
    private var elapsedTask: Task<Void, Never>?
    private var autoStopParameters: (localeIdentifier: String, outputLanguageMode: OutputLanguageMode)?

    /// Meetings stop themselves after this long. An unattended recording would
    /// otherwise grow two audio files plus a spilled transcription buffer without
    /// any bound.
    static let maximumRecordingDuration: TimeInterval = 4 * 60 * 60

    /// Headroom required before starting: two 16 kHz mono float streams for the
    /// maximum duration, rounded up.
    static let requiredFreeBytes: Int64 = 4_000_000_000

    init(speechEngine: ASREngineRouter, permissions: PermissionManager) {
        self.speechEngine = speechEngine
        self.permissions = permissions
    }

    func start(
        localeIdentifier: String,
        preferExtendedLanguages: Bool,
        outputLanguageMode: OutputLanguageMode = .original
    ) async {
        guard state != .recording, state != .processing else { return }
        guard await permissions.requestMicrophone() else {
            state = .error(AirScribeError.microphonePermissionDenied.localizedDescription)
            return
        }
        do {
            try Self.requireFreeSpace(at: store.audioDirectory)
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        resetCaptureState()
        autoStopParameters = (localeIdentifier, outputLanguageMode)
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
            self.microphoneURL = microphoneURL
            recovery.mark(.meeting, audioPaths: [microphoneURL.path])
            let systemURL = try store.newAudioURL(source: .computer)
            self.systemURL = systemURL
            recovery.mark(.meeting, audioPaths: [microphoneURL.path, systemURL.path])
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
                do {
                    try FileManager.default.removeItem(at: systemURL)
                    self.systemURL = nil
                } catch {
                    systemAudioStatus = "System audio unavailable — cleanup pending"
                }
            }

            startedAt = Date()
            startedAtInstant = .now
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
            let cleanupFailures = removeUnfinishedFiles()
            if cleanupFailures.isEmpty {
                recovery.complete()
            } else {
                recovery.presentMarkedSession()
            }
            state = .error(errorMessage(error, cleanupFailures: cleanupFailures))
        }
    }

    func stop(localeIdentifier: String, outputLanguageMode: OutputLanguageMode) async {
        guard state == .recording else { return }
        state = .processing
        elapsedTask?.cancel()
        elapsedTask = nil
        let audioRecordingError = stopCaptureHardware()
        var cleanupFailures: [String] = []
        if audioRecordingError != nil {
            cleanupFailures = removeUnfinishedFiles()
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
            switch outputLanguageMode {
            case .original:
                break
            case .romanizedHindi:
                if !microphoneText.isEmpty {
                    microphoneText = await translator.romanizeHindi(microphoneText)
                }
                if !systemText.isEmpty {
                    systemText = await translator.romanizeHindi(systemText)
                }
            case .english:
                if !microphoneText.isEmpty {
                    microphoneText = (try? await translator.translateToEnglish(microphoneText)) ?? microphoneText
                }
                if !systemText.isEmpty {
                    systemText = (try? await translator.translateToEnglish(systemText)) ?? systemText
                }
            }
            let duration = elapsedDuration()
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
            if cleanupFailures.isEmpty {
                recovery.complete()
            } else {
                recovery.presentMarkedSession()
            }
            state = .complete
            if let audioRecordingError {
                lastWarning = errorMessage(audioRecordingError, cleanupFailures: cleanupFailures)
            }
        } catch {
            cleanupFailures.append(contentsOf: removeUnfinishedFiles())
            cleanupFailures = Array(Set(cleanupFailures)).sorted()
            if cleanupFailures.isEmpty {
                recovery.complete()
            } else {
                recovery.presentMarkedSession()
            }
            state = .error(errorMessage(error, cleanupFailures: cleanupFailures))
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
        let cleanupFailures = removeUnfinishedFiles()
        if cleanupFailures.isEmpty {
            recovery.complete()
        } else {
            recovery.presentMarkedSession()
        }
        resetCaptureState()
        state = cleanupFailures.isEmpty
            ? .idle
            : .error("Some meeting audio could not be deleted: \(cleanupFailures.joined(separator: ", ")).")
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
        startedAtInstant = nil
        autoStopParameters = nil
        liveTranscript = ""
        microphonePartial = ""
        systemPartial = ""
        elapsedSeconds = 0
        microphoneLevel = 0
        latestRecord = nil
        systemAudioStatus = "System audio ready"
        lastWarning = nil
    }

    /// Wall-clock arithmetic drifts across sleep and clock changes, and counting
    /// one-second sleeps accumulates scheduling error, so elapsed time is derived
    /// from a monotonic instant instead.
    private func elapsedDuration() -> TimeInterval {
        guard let startedAtInstant else { return 0 }
        let components = startedAtInstant.duration(to: .now).components
        return max(TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000, 0)
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let elapsed = self.elapsedDuration()
                self.elapsedSeconds = Int(elapsed)
                guard elapsed >= Self.maximumRecordingDuration else { continue }
                self.lastWarning = "Recording stopped automatically after \(Int(Self.maximumRecordingDuration / 3_600)) hours."
                self.beginAutoStop()
                return
            }
        }
    }

    /// Ends a recording that hit the duration cap, reusing the language settings
    /// the meeting started with.
    ///
    /// `stop` cancels the elapsed-time task, so it must not be awaited from
    /// inside that task — transcription and summarisation would inherit the
    /// cancellation and abandon the recording.
    private func beginAutoStop() {
        guard let parameters = autoStopParameters else { return }
        Task { @MainActor [weak self] in
            await self?.stop(
                localeIdentifier: parameters.localeIdentifier,
                outputLanguageMode: parameters.outputLanguageMode
            )
        }
    }

    private static func requireFreeSpace(at url: URL) throws {
        let probe = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        guard let available = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else { return }
        guard available < requiredFreeBytes else { return }
        throw MeetingCaptureError.insufficientStorage(
            required: requiredFreeBytes,
            available: available
        )
    }

    @discardableResult
    private func stopCaptureHardware() -> Error? {
        let microphoneError = microphone.stop()
        systemAudio.stop()
        let systemError = systemWriter?.writeError
        systemWriter = nil
        return microphoneError ?? systemError
    }

    private func removeUnfinishedFiles() -> [String] {
        var failures: [String] = []
        for url in [microphoneURL, systemURL].compactMap({ $0 }) {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        microphoneURL = nil
        systemURL = nil
        return failures
    }

    private func errorMessage(_ error: Error, cleanupFailures: [String]) -> String {
        guard !cleanupFailures.isEmpty else { return error.localizedDescription }
        return "\(error.localizedDescription) Some meeting audio could not be deleted: \(cleanupFailures.joined(separator: ", "))."
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
        // AVAudioFile recreates the file, which can drop the owner-only mode
        // that the store applied when it reserved the path.
        FilePermissions.restrictToOwner(at: url)
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

struct MeetingSummarizer {
    /// A whole meeting transcript overflows the on-device model's context window,
    /// which failed silently and fell back to echoing the first few lines. Long
    /// transcripts are summarised in segments and those summaries are then reduced.
    static let maximumSegmentCharacters = 6_000
    static let maximumSegments = 24

    private static let summaryInstructions = """
        Summarize this meeting transcript locally. Return concise Markdown with sections for Overview, Decisions, and Action items.
        Do not invent facts, owners, dates, or decisions. Omit a section when the transcript provides none.
        """

    private static let reduceInstructions = """
        Merge these partial meeting summaries into one. Return concise Markdown with sections for Overview, Decisions, and Action items.
        Keep every distinct decision and action item. Do not invent facts, owners, or dates. Omit a section when nothing supports it.
        """

    func summarize(_ transcript: String) async -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return Self.outlineFallback(transcript) }

        let segments = Self.segments(of: transcript)
        var partials: [String] = []
        for segment in segments {
            guard let value = await Self.respond(
                to: segment,
                instructions: Self.summaryInstructions,
                model: model
            ) else { continue }
            partials.append(value)
        }

        if partials.isEmpty { return Self.outlineFallback(transcript) }
        if partials.count == 1 { return partials[0] }
        if let merged = await Self.respond(
            to: partials.enumerated()
                .map { "Part \($0.offset + 1):\n\($0.element)" }
                .joined(separator: "\n\n"),
            instructions: Self.reduceInstructions,
            model: model
        ) {
            return merged
        }
        return partials.joined(separator: "\n\n")
    }

    private static func respond(
        to prompt: String,
        instructions: String,
        model: SystemLanguageModel
    ) async -> String? {
        let session = LanguageModelSession(model: model, instructions: instructions)
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let value = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Splits on blank-line speaker turns so a segment never cuts a sentence.
    static func segments(of transcript: String) -> [String] {
        guard transcript.count > maximumSegmentCharacters else { return [transcript] }
        var segments: [String] = []
        var current = ""
        for turn in transcript.components(separatedBy: "\n\n") {
            if !current.isEmpty, current.count + turn.count + 2 > maximumSegmentCharacters {
                segments.append(current)
                current = ""
                if segments.count >= maximumSegments { break }
            }
            // A single turn longer than the budget still has to be split.
            if turn.count > maximumSegmentCharacters {
                var remainder = Substring(turn)
                while !remainder.isEmpty, segments.count < maximumSegments {
                    let end = remainder.index(
                        remainder.startIndex,
                        offsetBy: min(maximumSegmentCharacters, remainder.count)
                    )
                    segments.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                continue
            }
            current += current.isEmpty ? turn : "\n\n" + turn
        }
        if !current.isEmpty, segments.count < maximumSegments { segments.append(current) }
        return segments
    }

    private static func outlineFallback(_ transcript: String) -> String {
        let lines = transcript
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(6)
        return lines.map { "- \($0)" }.joined(separator: "\n")
    }
}
