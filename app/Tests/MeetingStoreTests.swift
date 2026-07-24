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

    func testCorruptMeetingHistoryIsNotOverwrittenByAddingARecord() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let meetingsURL = root.appending(path: "meetings.json")
        let damagedData = Data("{not-json".utf8)
        try damagedData.write(to: meetingsURL)

        let store = MeetingStore(applicationSupportRoot: root)

        XCTAssertThrowsError(try store.add(sampleRecord()))
        XCTAssertEqual(try Data(contentsOf: meetingsURL), damagedData)
        XCTAssertNotNil(store.lastError)
    }

    func testSensitiveMeetingFilesUseOwnerOnlyPermissions() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(applicationSupportRoot: root)
        let audioURL = try store.newAudioURL(source: .you)
        try store.add(sampleRecord(microphonePath: audioURL.path))

        XCTAssertEqual(posixPermissions(at: audioURL), 0o600)
        XCTAssertEqual(posixPermissions(at: root.appending(path: "meetings.json")), 0o600)
        XCTAssertEqual(posixPermissions(at: root), 0o700)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "AirScribeMeetingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func posixPermissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
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

    func testMeetingTitlesCarryTheExactDateAndTime() throws {
        // Two meetings a few seconds apart must stay distinguishable, which the
        // old minute-resolution title could not manage.
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = first.addingTimeInterval(7)
        let titles = [first, second].map {
            "Meeting " + $0.formatted(MeetingCoordinator.titleDateFormat)
        }
        XCTAssertNotEqual(titles[0], titles[1])
        for title in titles {
            XCTAssertTrue(title.contains(":"), "Title must include a time")
            // Seconds are what makes two meetings in the same minute distinct.
            XCTAssertEqual(title.filter { $0 == ":" }.count, 2, "Title needs hour, minute and second")
        }
    }
}
