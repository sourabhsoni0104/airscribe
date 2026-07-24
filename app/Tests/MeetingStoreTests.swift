import Foundation
import XCTest
@testable import AirScribe

@MainActor
final class MeetingStoreTests: XCTestCase {
    func testMeetingExportsContainTranscriptAndValidSRTTimecodes() {
        let record = sampleRecord()

        let markdown = MeetingExportFormat.markdown.render(record)
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("Computer: Welcome"))

        let subtitles = MeetingExportFormat.subtitles.render(record)
        XCTAssertTrue(subtitles.contains("00:00:00,000 --> 00:00:12,345"))
        XCTAssertTrue(subtitles.contains("Computer: Welcome to the meeting."))
    }

    func testDeletingMeetingOnlyRemovesManagedAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeMeetingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(applicationSupportRoot: root)
        let managed = try store.newAudioURL(source: .you)
        let outside = root.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString).caf")
        XCTAssertTrue(FileManager.default.createFile(atPath: managed.path, contents: Data("audio".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data("audio".utf8)))

        let original = sampleRecord(microphonePath: managed.path, systemPath: outside.path)
        try store.add(original)
        store.delete(original)

        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        try? FileManager.default.removeItem(at: outside)
    }

    private func sampleRecord(
        microphonePath: String? = nil,
        systemPath: String? = nil
    ) -> MeetingRecord {
        let segment = MeetingTranscriptSegment(
            speaker: .computer,
            startTime: 0,
            endTime: 12.345,
            text: "Welcome to the meeting."
        )
        return MeetingRecord(
            title: "Launch review",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12.345,
            localeIdentifier: "en-US",
            transcript: "Computer: Welcome to the meeting.",
            summary: "- Reviewed the launch.",
            segments: [segment],
            microphoneAudioPath: microphonePath,
            systemAudioPath: systemPath
        )
    }
}
