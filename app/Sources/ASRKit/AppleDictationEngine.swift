import AVFAudio
import CoreMedia
import Foundation
import Speech

struct AppleDictationEngine: TranscriptionEngine {
    let name = "AirScribe System Speech"

    func makeSession(
        locale: Locale,
        context: String?,
        partialResult: @escaping @Sendable (String) -> Void
    ) async throws -> any TranscriptionSession {
        guard let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AirScribeError.unsupportedLocale(locale.identifier)
        }

        var preset = DictationTranscriber.Preset.progressiveShortDictation
        preset.attributeOptions.insert(.audioTimeRange)
        let transcriber = DictationTranscriber(locale: supportedLocale, preset: preset)
        let modules: [any SpeechModule] = [transcriber]
        try await ensureAssets(for: modules, locale: supportedLocale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw AirScribeError.speechUnavailable
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let analysisContext = AnalysisContext()
        var contextualPhrases = ["AirScribe", "Hey AirScribe", "air scribe"]
        if let context, !context.isEmpty { contextualPhrases.append(context) }
        analysisContext.contextualStrings[.general] = contextualPhrases
        try await analyzer.setContext(analysisContext)
        try await analyzer.prepareToAnalyze(in: format)

        return AppleDictationSession(
            analyzer: analyzer,
            transcriber: transcriber,
            requiredAudioFormat: format,
            partialResult: partialResult
        )
    }

    private func ensureAssets(for modules: [any SpeechModule], locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            _ = try? await AssetInventory.reserve(locale: locale)
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            _ = try await AssetInventory.reserve(locale: locale)
        case .unsupported:
            throw AirScribeError.unsupportedLocale(locale.identifier)
        @unknown default:
            throw AirScribeError.speechUnavailable
        }
    }
}

final class AppleDictationSession: TranscriptionSession, @unchecked Sendable {
    let engineName = "AirScribe Models · System speech"
    let requiredAudioFormat: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analysisTask: Task<Void, Error>
    private let resultTask: Task<(text: String, timings: [TranscribedWordTiming]), Error>
    private let stateLock = NSLock()
    private var hasFinished = false
    private var completedWordTimings: [TranscribedWordTiming] = []
    private var capturedFrameCount: Int64 = 0

    var wordTimings: [TranscribedWordTiming] {
        stateLock.withLock { completedWordTimings }
    }

    var capturedAudioDuration: TimeInterval? {
        stateLock.withLock {
            guard requiredAudioFormat.sampleRate > 0 else { return nil }
            return Double(capturedFrameCount) / requiredAudioFormat.sampleRate
        }
    }

    init(
        analyzer: SpeechAnalyzer,
        transcriber: DictationTranscriber,
        requiredAudioFormat: AVAudioFormat,
        partialResult: @escaping @Sendable (String) -> Void
    ) {
        self.analyzer = analyzer
        self.requiredAudioFormat = requiredAudioFormat

        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(80))
        continuation = pair.continuation

        analysisTask = Task {
            try await analyzer.start(inputSequence: pair.stream)
        }
        resultTask = Task {
            var finalized = ""
            var volatile = ""
            var finalizedTimings: [TranscribedWordTiming] = []
            var volatileTimings: [TranscribedWordTiming] = []
            for try await result in transcriber.results {
                let value = String(result.text.characters)
                let timings = Self.extractWordTimings(from: result.text)
                if result.isFinal {
                    finalized = Self.join(finalized, value)
                    finalizedTimings.append(contentsOf: timings)
                    volatile = ""
                    volatileTimings = []
                } else {
                    volatile = value
                    volatileTimings = timings
                }
                partialResult(Self.join(finalized, volatile))
            }
            return (Self.join(finalized, volatile), finalizedTimings + volatileTimings)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let finished = stateLock.withLock {
            guard !hasFinished else { return true }
            capturedFrameCount += Int64(buffer.frameLength)
            return false
        }
        guard !finished else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> String {
        guard markFinished() else { return "" }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await analysisTask.value
        let result = try await resultTask.value
        stateLock.withLock { completedWordTimings = result.timings }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return PauseAwarePunctuation.apply(
            to: text,
            using: text,
            timings: result.timings,
            audioDuration: capturedAudioDuration
        )
    }

    func cancel() async {
        guard markFinished() else { return }
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        analysisTask.cancel()
        resultTask.cancel()
    }

    private func markFinished() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !hasFinished else { return false }
        hasFinished = true
        return true
    }

    private static func join(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if left.last?.isWhitespace == true || right.first?.isWhitespace == true {
            return left + right
        }
        return left + " " + right
    }

    private static func extractWordTimings(from text: AttributedString) -> [TranscribedWordTiming] {
        var output: [TranscribedWordTiming] = []
        for run in text.runs {
            guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let runText = String(text[run.range].characters)
            let words = runText.matches(of: /[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/).map { String($0.output) }
            guard !words.isEmpty else { continue }

            let start = CMTimeGetSeconds(timeRange.start)
            let duration = max(CMTimeGetSeconds(timeRange.duration), 0)
            guard start.isFinite, duration.isFinite else { continue }
            let wordDuration = duration / Double(words.count)
            for (index, word) in words.enumerated() {
                output.append(
                    TranscribedWordTiming(
                        text: word,
                        startTime: start + (Double(index) * wordDuration),
                        endTime: start + (Double(index + 1) * wordDuration)
                    )
                )
            }
        }
        return output
    }
}
