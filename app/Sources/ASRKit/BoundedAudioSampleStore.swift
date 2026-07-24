import Foundation

final class BoundedAudioSampleStore {
    struct Capture {
        let memorySamples: [Float]?
        let fileURL: URL?
        let sampleRate: Int
        let sampleCount: Int64
        /// True when capture stopped early because the spill cap was reached.
        let reachedCapacityLimit: Bool
        /// True when the input device changed sample rate mid-capture and the
        /// mismatched audio was dropped.
        let droppedMismatchedAudio: Bool

        init(
            memorySamples: [Float]?,
            fileURL: URL?,
            sampleRate: Int,
            sampleCount: Int64,
            reachedCapacityLimit: Bool = false,
            droppedMismatchedAudio: Bool = false
        ) {
            self.memorySamples = memorySamples
            self.fileURL = fileURL
            self.sampleRate = sampleRate
            self.sampleCount = sampleCount
            self.reachedCapacityLimit = reachedCapacityLimit
            self.droppedMismatchedAudio = droppedMismatchedAudio
        }

        var duration: TimeInterval {
            guard sampleRate > 0 else { return 0 }
            return TimeInterval(sampleCount) / TimeInterval(sampleRate)
        }

        func removeTemporaryFile() {
            guard let fileURL else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Ceiling on spilled audio for one capture. At 16 kHz mono float that is
    /// roughly six hours, which bounds disk use for an unattended meeting
    /// without truncating any realistic session.
    static let defaultMaximumSpillBytes: Int64 = 1_500_000_000

    private let memoryDuration: TimeInterval
    private let maximumSpillBytes: Int64
    private let fileManager: FileManager
    private var memorySamples: [Float] = []
    private var fileURL: URL?
    private var fileHandle: FileHandle?
    private var failureDescription: String?
    private var spilledBytes: Int64 = 0
    private var lockedSampleRate: Int?
    private(set) var reachedCapacityLimit = false
    private(set) var droppedMismatchedAudio = false
    private(set) var sampleRate = 16_000
    private(set) var sampleCount: Int64 = 0
    private var isFinished = false

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(sampleCount) / TimeInterval(sampleRate)
    }

    init(
        memoryDuration: TimeInterval = 90,
        maximumSpillBytes: Int64 = BoundedAudioSampleStore.defaultMaximumSpillBytes,
        fileManager: FileManager = .default
    ) {
        self.memoryDuration = memoryDuration
        self.maximumSpillBytes = maximumSpillBytes
        self.fileManager = fileManager
    }

    deinit {
        try? fileHandle?.close()
        if let fileURL { try? fileManager.removeItem(at: fileURL) }
    }

    func append(_ samples: [Float], sampleRate: Int) {
        guard !isFinished,
              failureDescription == nil,
              !samples.isEmpty,
              !reachedCapacityLimit else { return }

        let incomingRate = max(sampleRate, 1)
        if let lockedSampleRate {
            // Concatenating buffers recorded at different rates produces audio
            // that plays back and transcribes as gibberish. Keeping everything
            // captured before the input device changed is strictly better than
            // corrupting the whole recording.
            guard incomingRate == lockedSampleRate else {
                droppedMismatchedAudio = true
                return
            }
        } else {
            lockedSampleRate = incomingRate
            self.sampleRate = incomingRate
        }

        do {
            if let fileHandle {
                guard try appendToDisk(samples, handle: fileHandle) else { return }
            } else if memorySamples.count + samples.count <= Int(Double(self.sampleRate) * memoryDuration) {
                memorySamples.append(contentsOf: samples)
            } else {
                try beginSpillingToDisk()
                guard let fileHandle else { return }
                guard try appendToDisk(samples, handle: fileHandle) else { return }
            }
        } catch {
            failureDescription = error.localizedDescription
            return
        }
        sampleCount += Int64(samples.count)
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
            sampleCount: sampleCount,
            reachedCapacityLimit: reachedCapacityLimit,
            droppedMismatchedAudio: droppedMismatchedAudio
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
            attributes: [.posixPermissions: FilePermissions.ownerOnlyDirectory]
        )
        try fileManager.setAttributes(
            [.posixPermissions: FilePermissions.ownerOnlyDirectory],
            ofItemAtPath: directory.path
        )
        let url = directory.appending(path: "\(UUID().uuidString).pcm")
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: FilePermissions.ownerOnlyFile]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        fileURL = url
        fileHandle = handle
        _ = try appendToDisk(memorySamples, handle: handle)
        memorySamples.removeAll(keepingCapacity: false)
    }

    /// Writes samples to the spill file, refusing to grow it past the cap.
    /// Returns false when nothing was written because the cap was reached.
    private func appendToDisk(_ samples: [Float], handle: FileHandle) throws -> Bool {
        guard !samples.isEmpty else { return true }
        let byteCount = Int64(samples.count * MemoryLayout<Float>.size)
        guard spilledBytes + byteCount <= maximumSpillBytes else {
            reachedCapacityLimit = true
            return false
        }
        let data = samples.withUnsafeBytes { Data($0) }
        try handle.write(contentsOf: data)
        spilledBytes += byteCount
        return true
    }

    private func removeTemporaryFile() {
        guard let fileURL else { return }
        try? fileManager.removeItem(at: fileURL)
        self.fileURL = nil
    }
}

/// Picks the quietest point near the end of a chunk so that a fixed-duration cut
/// does not fall in the middle of a spoken word.
///
/// Splitting on a hard boundary made the word straddling it unrecognisable in
/// both chunks. Searching a short window backwards for minimum energy moves the
/// cut into a pause instead. Returns `preferred` when the buffer is too small
/// for the search to be meaningful.
func silenceAwareSplitIndex(
    in samples: [Float],
    from start: Int,
    preferred: Int,
    searchSpan: Int,
    windowSize: Int
) -> Int {
    guard preferred < samples.count else { return samples.count }
    guard windowSize > 0,
          searchSpan >= windowSize,
          preferred - start > searchSpan * 2 else { return preferred }

    let lowerBound = max(start + windowSize, preferred - searchSpan)
    guard lowerBound < preferred else { return preferred }

    var bestIndex = preferred
    var bestEnergy = Float.greatestFiniteMagnitude
    var windowStart = lowerBound
    while windowStart < preferred {
        let windowEnd = min(windowStart + windowSize, preferred)
        var energy: Float = 0
        for index in windowStart ..< windowEnd {
            energy += samples[index] * samples[index]
        }
        if energy < bestEnergy {
            bestEnergy = energy
            bestIndex = windowEnd
        }
        windowStart += windowSize
    }
    return bestIndex
}

func transcribeBoundedAudio(
    _ capture: BoundedAudioSampleStore.Capture,
    maximumChunkDuration: TimeInterval = 300,
    operation: ([Float], Int) async throws -> String
) async throws -> String {
    defer { capture.removeTemporaryFile() }
    let chunkSize = max(Int(Double(capture.sampleRate) * maximumChunkDuration), 1)
    // Look for a pause in the last 1.5 s of a chunk, scanning in 20 ms windows.
    let searchSpan = max(Int(Double(capture.sampleRate) * 1.5), 1)
    let windowSize = max(Int(Double(capture.sampleRate) * 0.02), 1)
    var results: [String] = []

    func transcribe(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        let text = try await operation(samples, capture.sampleRate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { results.append(text) }
    }

    if let memorySamples = capture.memorySamples {
        var offset = 0
        while offset < memorySamples.count {
            let end = silenceAwareSplitIndex(
                in: memorySamples,
                from: offset,
                preferred: min(offset + chunkSize, memorySamples.count),
                searchSpan: searchSpan,
                windowSize: windowSize
            )
            try await transcribe(Array(memorySamples[offset ..< end]))
            offset = end
        }
    } else if let fileURL = capture.fileURL {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let byteCount = chunkSize * MemoryLayout<Float>.size
        // Carry the tail of a chunk forward so the split can land in a pause
        // instead of at the exact byte boundary the read returned.
        var pending: [Float] = []
        while let data = try handle.read(upToCount: byteCount), !data.isEmpty {
            let count = data.count / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination)
            }
            pending.append(contentsOf: samples)
            while pending.count >= chunkSize {
                let end = silenceAwareSplitIndex(
                    in: pending,
                    from: 0,
                    preferred: chunkSize,
                    searchSpan: searchSpan,
                    windowSize: windowSize
                )
                try await transcribe(Array(pending[0 ..< end]))
                pending.removeFirst(end)
            }
        }
        try await transcribe(pending)
    }

    return results.joined(separator: " ")
}
