import AVFAudio
import XCTest
@testable import AirScribe

@MainActor
final class ModelRuntimeIntegrationTests: XCTestCase {
    func testInstalledModelTranscribesSpeechFixture() async throws {
        let fixture = URL(filePath: "/tmp/airscribe-runtime-test.aiff")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Generate the local speech fixture before running the model integration test.")
        }

        let manager = ModelManager()
        guard manager.state == .installed else {
            throw XCTSkip("AirScribe Models are not installed on this Mac.")
        }

        let file = try AVAudioFile(forReading: fixture)
        let frameCapacity = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCapacity)!
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            XCTFail("Speech fixture is not PCM float audio.")
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(Int(buffer.format.channelCount), 1)
        var samples = [Float](repeating: 0, count: frameCount)
        for channel in 0 ..< channelCount {
            for frame in 0 ..< frameCount {
                samples[frame] += channelData[channel][frame] / Float(channelCount)
            }
        }

        let runtime = QwenASRRuntime(modelDirectory: manager.modelDirectory)
        let result = try await runtime.transcribe(
            samples: samples,
            sampleRate: Int(buffer.format.sampleRate.rounded()),
            language: "en",
            context: "AirScribe"
        )
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(result.localizedCaseInsensitiveContains("AirScribe") || result.localizedCaseInsensitiveContains("private"))
    }
}
