import XCTest
@testable import AirScribe

final class MeetingSummarizerTests: XCTestCase {
    func testShortTranscriptIsASingleSegment() {
        let transcript = "You: Let's ship on Friday.\n\nComputer: Agreed."
        XCTAssertEqual(MeetingSummarizer.segments(of: transcript), [transcript])
    }

    func testLongTranscriptIsSplitOnSpeakerTurns() {
        let turn = "You: " + String(repeating: "word ", count: 400)
        let transcript = Array(repeating: turn, count: 6).joined(separator: "\n\n")

        let segments = MeetingSummarizer.segments(of: transcript)
        XCTAssertGreaterThan(segments.count, 1, "A transcript past the budget must be chunked")
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.count, MeetingSummarizer.maximumSegmentCharacters)
        }
        // No content may be lost when chunking.
        let rejoined = segments.joined(separator: "\n\n")
        XCTAssertEqual(
            rejoined.filter { !$0.isWhitespace },
            transcript.filter { !$0.isWhitespace }
        )
    }

    func testASingleOversizedTurnIsStillSplit() {
        let transcript = "You: " + String(repeating: "x", count: 20_000)
        let segments = MeetingSummarizer.segments(of: transcript)
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.count, MeetingSummarizer.maximumSegmentCharacters)
        }
    }

    func testSegmentCountIsBounded() {
        let turn = "You: " + String(repeating: "word ", count: 2_000)
        let transcript = Array(repeating: turn, count: 400).joined(separator: "\n\n")
        XCTAssertLessThanOrEqual(
            MeetingSummarizer.segments(of: transcript).count,
            MeetingSummarizer.maximumSegments
        )
    }
}
