@preconcurrency import AVFAudio
import Foundation
import Qwen3ASR

@MainActor
final class ASREngineRouter: TranscriptionEngine, @unchecked Sendable {
    let name = "AirScribe Models"

    private let modelManager: ModelManager
    private let languagePackManager: LanguagePackManager
    private let appleEngine = AppleDictationEngine()
    private let qwenRuntime: QwenASRRuntime

    init(modelManager: ModelManager, languagePackManager: LanguagePackManager) {
        self.modelManager = modelManager
        self.languagePackManager = languagePackManager
        qwenRuntime = QwenASRRuntime(modelDirectory: modelManager.modelDirectory)
    }

    func warmUpIfAvailable() async {
        guard modelManager.state == .installed else { return }
        try? await qwenRuntime.prepare()
    }

    func makeSession(
        locale: Locale,
        context: String?,
        partialResult: @escaping @Sendable (String) -> Void
    ) async throws -> any TranscriptionSession {
        try await makeSession(
            locale: locale,
            context: context,
            preferExtendedLanguages: false,
            partialResult: partialResult
        )
    }

    func makeSession(
        locale: Locale,
        context: String?,
        preferExtendedLanguages: Bool = false,
        partialResult: @escaping @Sendable (String) -> Void
    ) async throws -> any TranscriptionSession {
        if preferExtendedLanguages, languagePackManager.state == .installed {
            let languageCode = locale.identifier == "auto"
                ? nil
                : locale.language.languageCode?.identifier
            let extended = ExtendedLanguageTranscriptionSession(
                runtime: languagePackManager.runtime,
                language: languageCode
            )
            if let apple = try? await appleEngine.makeSession(
                locale: locale.identifier == "auto" ? Locale.current : locale,
                context: context,
                partialResult: partialResult
            ) {
                return HybridExtendedTranscriptionSession(apple: apple, extended: extended)
            }
            return extended
        }

        guard modelManager.state == .installed else {
            return try await appleEngine.makeSession(
                locale: locale,
                context: context,
                partialResult: partialResult
            )
        }

        let languageCode = locale.language.languageCode?.identifier
        if let apple = try? await appleEngine.makeSession(
            locale: locale,
            context: context,
            partialResult: partialResult
        ) {
            let qwen = QwenTranscriptionSession(
                runtime: qwenRuntime,
                requiredAudioFormat: apple.requiredAudioFormat,
                language: languageCode,
                context: context
            )
            return HybridTranscriptionSession(apple: apple, qwen: qwen)
        }

        return QwenTranscriptionSession(
            runtime: qwenRuntime,
            language: languageCode,
            context: context
        )
    }
}

private final class ExtendedLanguageTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    let engineName = "AirScribe Models · 100+ languages"
    let requiredAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private let runtime: ExtendedLanguageRuntime
    private let language: String?
    private let lock = NSLock()
    private let audio = BoundedAudioSampleStore()

    var capturedAudioDuration: TimeInterval? {
        lock.withLock { audio.duration }
    }

    init(runtime: ExtendedLanguageRuntime, language: String?) {
        self.runtime = runtime
        self.language = language
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(Int(buffer.format.channelCount), 1)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0 ..< channelCount {
            for frame in 0 ..< frameCount {
                mono[frame] += channels[channel][frame] / Float(channelCount)
            }
        }
        lock.withLock {
            audio.append(mono, sampleRate: Int(buffer.format.sampleRate.rounded()))
        }
    }

    func finish() async throws -> String {
        guard let capture = try lock.withLock({ try audio.finish() }),
              capture.sampleCount > 0 else { throw AirScribeError.emptyTranscription }
        return try await transcribeBoundedAudio(capture) { [runtime, language] samples, sampleRate in
            try await runtime.transcribe(samples: samples, sampleRate: sampleRate, language: language)
        }
    }

    func cancel() async {
        lock.withLock { audio.cancel() }
    }
}

private final class HybridExtendedTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    let engineName = "AirScribe Models · 100+ languages"
    let requiredAudioFormat: AVAudioFormat
    private let apple: any TranscriptionSession
    private let extended: ExtendedLanguageTranscriptionSession

    init(apple: any TranscriptionSession, extended: ExtendedLanguageTranscriptionSession) {
        self.apple = apple
        self.extended = extended
        requiredAudioFormat = apple.requiredAudioFormat
    }

    var wordTimings: [TranscribedWordTiming] { apple.wordTimings }
    var capturedAudioDuration: TimeInterval? { apple.capturedAudioDuration ?? extended.capturedAudioDuration }

    func append(_ buffer: AVAudioPCMBuffer) {
        apple.append(buffer)
        extended.append(buffer)
    }

    func finish() async throws -> String {
        async let fallback = apple.finish()
        do {
            let result = try await extended.finish()
            let systemResult = try? await fallback
            guard !result.isEmpty else { throw AirScribeError.emptyTranscription }
            if let systemResult {
                return PauseAwarePunctuation.apply(
                    to: result,
                    using: systemResult,
                    timings: apple.wordTimings,
                    audioDuration: apple.capturedAudioDuration
                )
            }
            return result
        } catch {
            let result = try await fallback
            guard !result.isEmpty else { throw error }
            return result
        }
    }

    func cancel() async {
        async let first: Void = apple.cancel()
        async let second: Void = extended.cancel()
        _ = await (first, second)
    }
}

actor QwenASRRuntime {
    private let modelDirectory: URL
    private var model: Qwen3ASRModel?

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func prepare() async throws {
        guard model == nil else { return }
        model = try await Qwen3ASRModel.fromPretrained(
            modelId: ModelManager.modelID,
            cacheDir: modelDirectory,
            offlineMode: true
        )
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        language: String?,
        context: String?
    ) async throws -> String {
        try await prepare()
        guard let model else { throw AirScribeError.speechUnavailable }
        return model.transcribe(
            audio: samples,
            sampleRate: sampleRate,
            language: language,
            context: context
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class QwenTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    let engineName = "AirScribe Models · On-device"
    let requiredAudioFormat: AVAudioFormat

    private let runtime: QwenASRRuntime
    private let language: String?
    private let context: String?
    private let lock = NSLock()
    private let audio = BoundedAudioSampleStore()

    var capturedAudioDuration: TimeInterval? {
        lock.withLock { audio.duration }
    }

    init(
        runtime: QwenASRRuntime,
        requiredAudioFormat: AVAudioFormat? = nil,
        language: String?,
        context: String?
    ) {
        self.runtime = runtime
        self.language = language
        self.context = context
        self.requiredAudioFormat = requiredAudioFormat
            ?? AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(Int(buffer.format.channelCount), 1)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0 ..< channelCount {
            for frame in 0 ..< frameCount {
                mono[frame] += channels[channel][frame] / Float(channelCount)
            }
        }

        lock.withLock {
            audio.append(mono, sampleRate: Int(buffer.format.sampleRate.rounded()))
        }
    }

    func finish() async throws -> String {
        guard let capture = try lock.withLock({ try audio.finish() }) else { return "" }
        guard capture.sampleCount > 0 else { throw AirScribeError.emptyTranscription }
        return try await transcribeBoundedAudio(capture) { [runtime, language, context] samples, sampleRate in
            try await runtime.transcribe(
                samples: samples,
                sampleRate: sampleRate,
                language: language,
                context: context
            )
        }
    }

    func cancel() async {
        lock.withLock { audio.cancel() }
    }
}

private final class HybridTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let stateLock = NSLock()
    private var resolvedEngineName = "AirScribe Models · On-device"
    var engineName: String { stateLock.withLock { resolvedEngineName } }
    let requiredAudioFormat: AVAudioFormat

    private let apple: any TranscriptionSession
    private let qwen: QwenTranscriptionSession

    init(apple: any TranscriptionSession, qwen: QwenTranscriptionSession) {
        self.apple = apple
        self.qwen = qwen
        requiredAudioFormat = apple.requiredAudioFormat
    }

    var wordTimings: [TranscribedWordTiming] { apple.wordTimings }
    var capturedAudioDuration: TimeInterval? { apple.capturedAudioDuration ?? qwen.capturedAudioDuration }

    func append(_ buffer: AVAudioPCMBuffer) {
        apple.append(buffer)
        qwen.append(buffer)
    }

    func finish() async throws -> String {
        async let appleResult = apple.finish()
        do {
            let qwenResult = try await qwen.finish()
            let systemResult = try? await appleResult
            guard !qwenResult.isEmpty else { throw AirScribeError.emptyTranscription }
            let assistant = AssistantEngine()
            if let systemResult,
               assistant.invocation(in: systemResult) != nil,
               assistant.invocation(in: qwenResult) == nil {
                return systemResult
            }
            if let systemResult {
                return PauseAwarePunctuation.apply(
                    to: qwenResult,
                    using: systemResult,
                    timings: apple.wordTimings,
                    audioDuration: apple.capturedAudioDuration
                )
            }
            return qwenResult
        } catch {
            let fallback = try await appleResult
            guard !fallback.isEmpty else { throw error }
            stateLock.withLock {
                resolvedEngineName = "AirScribe Models · System fallback"
            }
            return fallback
        }
    }

    func cancel() async {
        async let cancelApple: Void = apple.cancel()
        async let cancelQwen: Void = qwen.cancel()
        _ = await (cancelApple, cancelQwen)
    }
}
