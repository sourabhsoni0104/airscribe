import Foundation

final class BoundedAudioSampleStore {
    struct Capture {
        let memorySamples: [Float]?
        let fileURL: URL?
        let sampleRate: Int
        let sampleCount: Int64

        var duration: TimeInterval {
            guard sampleRate > 0 else { return 0 }
            return TimeInterval(sampleCount) / TimeInterval(sampleRate)
        }

        func removeTemporaryFile() {
            guard let fileURL else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private let memoryDuration: TimeInterval
    private let fileManager: FileManager
    private var memorySamples: [Float] = []
    private var fileURL: URL?
    private var fileHandle: FileHandle?
    private var failureDescription: String?
    private(set) var sampleRate = 16_000
    private(set) var sampleCount: Int64 = 0
    private var isFinished = false

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(sampleCount) / TimeInterval(sampleRate)
    }

    init(memoryDuration: TimeInterval = 90, fileManager: FileManager = .default) {
        self.memoryDuration = memoryDuration
        self.fileManager = fileManager
    }

    deinit {
        try? fileHandle?.close()
        if let fileURL { try? fileManager.removeItem(at: fileURL) }
    }

    func append(_ samples: [Float], sampleRate: Int) {
        guard !isFinished, failureDescription == nil, !samples.isEmpty else { return }
        self.sampleRate = max(sampleRate, 1)
        sampleCount += Int64(samples.count)

        do {
            if let fileHandle {
                try write(samples, to: fileHandle)
            } else if memorySamples.count + samples.count <= Int(Double(self.sampleRate) * memoryDuration) {
                memorySamples.append(contentsOf: samples)
            } else {
                try beginSpillingToDisk()
                guard let fileHandle else { return }
                try write(samples, to: fileHandle)
            }
        } catch {
            failureDescription = error.localizedDescription
        }
    }

    func finish() throws -> Capture? {
        guard !isFinished else { return nil }
        isFinished = true
        try? fileHandle?.close()
        fileHandle = nil

        if let failureDescription {
            removeTemporaryFile()
            throw NSError(
                domain: "AirScribe.AudioBuffer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio buffering failed: \(failureDescription)"]
            )
        }

        let capture = Capture(
            memorySamples: fileURL == nil ? memorySamples : nil,
            fileURL: fileURL,
            sampleRate: sampleRate,
            sampleCount: sampleCount
        )
        memorySamples.removeAll(keepingCapacity: false)
        fileURL = nil
        return capture
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        try? fileHandle?.close()
        fileHandle = nil
        memorySamples.removeAll(keepingCapacity: false)
        removeTemporaryFile()
    }

    private func beginSpillingToDisk() throws {
        let directory = fileManager.temporaryDirectory
            .appending(path: "AirScribe", directoryHint: .isDirectory)
            .appending(path: "TranscriptionBuffers", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appending(path: "\(UUID().uuidString).pcm")
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        fileURL = url
        fileHandle = handle
        try write(memorySamples, to: handle)
        memorySamples.removeAll(keepingCapacity: false)
    }

    private func write(_ samples: [Float], to handle: FileHandle) throws {
        let data = samples.withUnsafeBytes { Data($0) }
        try handle.write(contentsOf: data)
    }

    private func removeTemporaryFile() {
        guard let fileURL else { return }
        try? fileManager.removeItem(at: fileURL)
        self.fileURL = nil
    }
}

func transcribeBoundedAudio(
    _ capture: BoundedAudioSampleStore.Capture,
    maximumChunkDuration: TimeInterval = 300,
    operation: ([Float], Int) async throws -> String
) async throws -> String {
    defer { capture.removeTemporaryFile() }
    let chunkSize = max(Int(Double(capture.sampleRate) * maximumChunkDuration), 1)
    var results: [String] = []

    if let memorySamples = capture.memorySamples {
        var offset = 0
        while offset < memorySamples.count {
            let end = min(offset + chunkSize, memorySamples.count)
            let text = try await operation(Array(memorySamples[offset ..< end]), capture.sampleRate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { results.append(text) }
            offset = end
        }
    } else if let fileURL = capture.fileURL {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let byteCount = chunkSize * MemoryLayout<Float>.size
        while let data = try handle.read(upToCount: byteCount), !data.isEmpty {
            let count = data.count / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination)
            }
            let text = try await operation(samples, capture.sampleRate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { results.append(text) }
        }
    }

    return results.joined(separator: " ")
}
