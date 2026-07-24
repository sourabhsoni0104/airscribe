@preconcurrency import AVFAudio
import Foundation

private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasProvided = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var recordingFile: AVAudioFile?
    private var isRunning = false

    var naturalFormat: AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    func start(
        targetFormat: AVAudioFormat,
        recordingURL: URL? = nil,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AirScribeError.audioConfiguration("No microphone input format is available.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AirScribeError.audioConfiguration("The microphone format cannot be converted for speech recognition.")
        }

        self.converter = converter
        self.targetFormat = targetFormat
        if let recordingURL {
            recordingFile = try AVAudioFile(
                forWriting: recordingURL,
                settings: targetFormat.settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            onLevel(Self.rootMeanSquareLevel(buffer))
            try? self.recordingFile?.write(from: converted)
            onBuffer(converted)
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            self.targetFormat = nil
            self.recordingFile = nil
            throw AirScribeError.audioConfiguration(error.localizedDescription)
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        targetFormat = nil
        recordingFile = nil
        isRunning = false
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let targetFormat else { return nil }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        let converterInput = ConverterInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if converterInput.wasProvided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            converterInput.wasProvided = true
            inputStatus.pointee = .haveData
            return converterInput.buffer
        }

        guard conversionError == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private static func rootMeanSquareLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0 ..< Int(buffer.frameLength) {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return min(max(rms * 7, 0), 1)
    }
}
