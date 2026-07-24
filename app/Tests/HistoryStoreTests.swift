import Foundation
import XCTest
@testable import AirScribe

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testLegacyHistoryWithoutAudioPathStillLoads() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let appDirectory = root.appending(path: "AirScribe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let json = """
        [{
          "id": "9A281714-5D2D-4C86-BF31-5752AE43C6D5",
          "createdAt": "2026-07-22T06:00:00Z",
          "rawText": "hello",
          "enhancedText": "Hello.",
          "mode": "General",
          "localeIdentifier": "en-US",
          "engine": "Apple on-device",
          "latencyMilliseconds": 84
        }]
        """
        try Data(json.utf8).write(to: appDirectory.appending(path: "history.json"))

        let store = HistoryStore(applicationSupportRoot: root)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.records[0].audioPath)
        XCTAssertEqual(store.records[0].enhancedText, "Hello.")
    }

    func testDeletingRecordRemovesOnlyManagedAudio() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(applicationSupportRoot: root)
        let managedAudio = try store.newAudioURL()
        try Data([1, 2, 3]).write(to: managedAudio)
        let outsideAudio = root.appending(path: "keep.caf")
        try Data([4, 5, 6]).write(to: outsideAudio)

        let managedRecord = makeRecord(audioPath: managedAudio.path)
        let outsideRecord = makeRecord(audioPath: outsideAudio.path)
        try store.add(outsideRecord)
        try store.add(managedRecord)
        store.delete(managedRecord)
        store.delete(outsideRecord)

        XCTAssertFalse(FileManager.default.fileExists(atPath: managedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideAudio.path))
        XCTAssertTrue(store.records.isEmpty)
    }

    func testSearchMatchesRawAndEnhancedText() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(applicationSupportRoot: root)
        try store.add(makeRecord(raw: "private speech models", enhanced: "AirScribe Models"))

        XCTAssertEqual(store.search("speech").count, 1)
        XCTAssertEqual(store.search("AIRSCRIBE MODELS").count, 1)
        XCTAssertTrue(store.search("unrelated").isEmpty)
    }

    func testEvictingOldRecordRemovesItsManagedAudio() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(applicationSupportRoot: root, maximumRecordCount: 1)
        let oldAudio = try store.newAudioURL()
        try Data([1, 2, 3]).write(to: oldAudio)

        try store.add(makeRecord(raw: "old", audioPath: oldAudio.path))
        try store.add(makeRecord(raw: "new"))

        XCTAssertEqual(store.records.map(\.rawText), ["new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio.path))
    }

    func testDeleteAllRemovesOrphanedManagedAudio() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(applicationSupportRoot: root)
        let orphanedAudio = try store.newAudioURL()
        try Data([1, 2, 3]).write(to: orphanedAudio)

        store.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedAudio.path))
        XCTAssertTrue(store.records.isEmpty)
    }

    private func makeRecord(
        raw: String = "test",
        enhanced: String = "Test.",
        audioPath: String? = nil
    ) -> DictationRecord {
        DictationRecord(
            rawText: raw,
            enhancedText: enhanced,
            mode: .general,
            localeIdentifier: "en-US",
            engine: "test",
            latencyMilliseconds: 10,
            audioPath: audioPath
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "AirScribeHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
