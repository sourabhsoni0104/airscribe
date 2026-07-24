import XCTest
@testable import AirScribe

final class AudioChunkingTests: XCTestCase {
    func testSplitMovesIntoTheQuietestNearbyWindow() {
        let sampleRate = 16_000
        // One second of tone, a short silence, then more tone. The preferred cut
        // lands inside the second tone; the split should back into the silence.
        var samples = [Float](repeating: 0.5, count: sampleRate)
        samples += [Float](repeating: 0.0, count: sampleRate / 10)
        samples += [Float](repeating: 0.5, count: sampleRate)

        let silenceStart = sampleRate
        let silenceEnd = sampleRate + sampleRate / 10
        // The search window has to be short relative to the chunk, as it is for a
        // real 300 s chunk; otherwise the split is left where it was asked for.
        let split = silenceAwareSplitIndex(
            in: samples,
            from: 0,
            preferred: silenceEnd + 2_000,
            searchSpan: Int(Double(sampleRate) * 0.5),
            windowSize: Int(Double(sampleRate) * 0.02)
        )

        XCTAssertGreaterThanOrEqual(split, silenceStart)
        XCTAssertLessThanOrEqual(split, silenceEnd)
    }

    func testSplitIsUnchangedWhenTheBufferIsTooSmallToSearch() {
        let samples = [Float](repeating: 0.5, count: 100)
        XCTAssertEqual(
            silenceAwareSplitIndex(in: samples, from: 0, preferred: 40, searchSpan: 30, windowSize: 10),
            40
        )
    }

    func testSplitReturnsEndOfBufferForTheFinalChunk() {
        let samples = [Float](repeating: 0.5, count: 100)
        XCTAssertEqual(
            silenceAwareSplitIndex(in: samples, from: 0, preferred: 100, searchSpan: 30, windowSize: 10),
            100
        )
    }

    func testCaptureStopsGrowingOnceTheSpillCapIsReached() throws {
        // A 4 KB cap allows exactly 1_000 floats on disk.
        let store = BoundedAudioSampleStore(memoryDuration: 0, maximumSpillBytes: 4_000)
        store.append([Float](repeating: 0.1, count: 900), sampleRate: 16_000)
        store.append([Float](repeating: 0.1, count: 900), sampleRate: 16_000)
        let capture = try XCTUnwrap(store.finish())
        defer { capture.removeTemporaryFile() }

        XCTAssertTrue(capture.reachedCapacityLimit)
        XCTAssertEqual(capture.sampleCount, 900, "Audio past the cap is refused, not silently written")
    }

    func testMismatchedSampleRateAudioIsDroppedRatherThanConcatenated() throws {
        let store = BoundedAudioSampleStore(memoryDuration: 60)
        store.append([Float](repeating: 0.1, count: 160), sampleRate: 16_000)
        store.append([Float](repeating: 0.2, count: 480), sampleRate: 48_000)
        let capture = try XCTUnwrap(store.finish())
        defer { capture.removeTemporaryFile() }

        XCTAssertTrue(capture.droppedMismatchedAudio)
        XCTAssertEqual(capture.sampleRate, 16_000)
        XCTAssertEqual(capture.sampleCount, 160)
        XCTAssertEqual(capture.memorySamples?.count, 160)
    }

    func testMemoryCaptureIsTranscribedInFullAcrossChunks() async throws {
        let store = BoundedAudioSampleStore(memoryDuration: 60)
        store.append([Float](repeating: 0.4, count: 300), sampleRate: 100)
        let capture = try XCTUnwrap(store.finish())

        var total = 0
        let result = try await transcribeBoundedAudio(capture, maximumChunkDuration: 1) { samples, rate in
            XCTAssertEqual(rate, 100)
            total += samples.count
            return "\(samples.count)"
        }

        XCTAssertEqual(total, 300, "Every sample must reach the engine exactly once")
        XCTAssertFalse(result.isEmpty)
    }
}
