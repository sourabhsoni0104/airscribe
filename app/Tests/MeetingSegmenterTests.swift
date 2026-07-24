import XCTest
@testable import AirScribe

final class MeetingSegmenterTests: XCTestCase {
    func testCreatesSentenceLevelSubtitleSegments() {
        let segments = MeetingSegmenter.segments(
            text: "Welcome everyone. We approved the launch date! Sourabh will send the plan.",
            speaker: .computer,
            timings: [],
            duration: 12
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.first?.startTime, 0)
        XCTAssertEqual(segments.last?.endTime, 12)
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.endTime <= $1.startTime })
    }

    func testUsesAvailableWordTimings() {
        let timings = [
            TranscribedWordTiming(text: "First", startTime: 2, endTime: 2.4),
            TranscribedWordTiming(text: "sentence.", startTime: 2.5, endTime: 3),
            TranscribedWordTiming(text: "Second", startTime: 5, endTime: 5.4),
            TranscribedWordTiming(text: "sentence.", startTime: 5.5, endTime: 6),
        ]

        let segments = MeetingSegmenter.segments(
            text: "First sentence. Second sentence.",
            speaker: .you,
            timings: timings,
            duration: 20
        )

        XCTAssertEqual(segments.map(\.startTime), [2, 5])
        XCTAssertEqual(segments.map(\.endTime), [3, 6])
    }
}
