import XCTest
@testable import AirScribe

final class FeedbackComposerTests: XCTestCase {
    func testBuildsAMailtoURLWithSubjectAndBody() throws {
        let url = try XCTUnwrap(
            FeedbackComposer.mailURL(subject: "AirScribe feedback", body: "Line one\nLine two")
        )
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertEqual(url.path, FeedbackComposer.recipient)

        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "subject" }?.value, "AirScribe feedback")
        XCTAssertEqual(query.first { $0.name == "body" }?.value, "Line one\nLine two")
    }

    func testSubjectsAndBodiesWithSpecialCharactersStaySafe() throws {
        let url = try XCTUnwrap(
            FeedbackComposer.mailURL(subject: "crash & burn?", body: "a=b&c=d #tag")
        )
        // An unencoded ampersand would split the body into a bogus extra
        // parameter and truncate the message. A question mark is legal in a query
        // value and is left alone, which is fine.
        XCTAssertFalse(url.absoluteString.contains("a=b&c=d"))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "subject" }?.value, "crash & burn?")
        XCTAssertEqual(query.first { $0.name == "body" }?.value, "a=b&c=d #tag")
    }

    func testDiagnosticsAreReadable() {
        XCTAssertFalse(FeedbackComposer.appVersion.isEmpty)
        XCTAssertNotEqual(FeedbackComposer.systemVersion, "0.0.0")
        XCTAssertFalse(FeedbackComposer.hardwareModel.isEmpty)
    }

    func testRecipientIsAnAddress() {
        XCTAssertTrue(FeedbackComposer.recipient.contains("@"))
        XCTAssertFalse(FeedbackComposer.recipient.hasPrefix("mailto:"))
    }
}
