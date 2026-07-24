import XCTest
@testable import AirScribe

final class BoundedAudioSampleStoreTests: XCTestCase {
    func testSpilledAudioIsReadInBoundedChunksAndRemoved() async throws {
        let store = BoundedAudioSampleStore(memoryDuration: 0)
        store.append([1, 2, 3, 4, 5], sampleRate: 2)
        let capture = try XCTUnwrap(store.finish())
        let temporaryURL = try XCTUnwrap(capture.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        var chunkSizes: [Int] = []

        let result = try await transcribeBoundedAudio(
            capture,
            maximumChunkDuration: 1
        ) { samples, _ in
            chunkSizes.append(samples.count)
            return "\(samples.count)"
        }

        XCTAssertEqual(chunkSizes, [2, 2, 1])
        XCTAssertEqual(result, "2 2 1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }
}
