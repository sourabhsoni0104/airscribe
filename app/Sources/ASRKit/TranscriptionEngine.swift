import AVFAudio
import Foundation

struct TranscribedWordTiming: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

protocol TranscriptionSession: AnyObject, Sendable {
    var engineName: String { get }
    var requiredAudioFormat: AVAudioFormat { get }
    var wordTimings: [TranscribedWordTiming] { get }
    var capturedAudioDuration: TimeInterval? { get }
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel() async
}

extension TranscriptionSession {
    var wordTimings: [TranscribedWordTiming] { [] }
    var capturedAudioDuration: TimeInterval? { nil }
}

@MainActor
protocol TranscriptionEngine: Sendable {
    var name: String { get }
    func makeSession(
        locale: Locale,
        context: String?,
        partialResult: @escaping @Sendable (String) -> Void
    ) async throws -> any TranscriptionSession
}
