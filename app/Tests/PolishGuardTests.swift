import XCTest
@testable import AirScribe

final class PolishGuardTests: XCTestCase {
    private let dictation = """
        So I wanted to walk through the migration plan for the billing service before Thursday, \
        because the rollout depends on the new schema landing first and the team needs time to \
        review it. There are 3 open questions about retries that we should settle in the meeting.
        """

    func testAcceptsTightenedPolish() {
        let polished = """
            I wanted to walk through the billing service migration plan before Thursday: the \
            rollout depends on the new schema landing first, and the team needs review time. \
            There are 3 open questions about retries to settle in the meeting.
            """
        XCTAssertTrue(PolishGuard.isPlausible(polished, polishOf: dictation))
    }

    func testRejectsTruncatedPolish() {
        // What a token-limited generation looks like: the tail is simply missing.
        let truncated = "I wanted to walk through the migration plan for the billing"
        XCTAssertFalse(PolishGuard.isPlausible(truncated, polishOf: dictation))
    }

    func testRejectsPolishThatDropsNumbers() {
        let withoutNumber = """
            I wanted to walk through the billing service migration plan before Thursday, since \
            the rollout depends on the new schema and the team needs time to review it. There \
            are several open questions about retries that we should settle in the meeting soon.
            """
        XCTAssertFalse(PolishGuard.isPlausible(withoutNumber, polishOf: dictation))
    }

    func testRejectsEmptyPolish() {
        XCTAssertFalse(PolishGuard.isPlausible("   ", polishOf: dictation))
    }

    func testRejectsRunawayPolish() {
        let padded = String(repeating: "The speaker discussed the migration at length. ", count: 40)
        XCTAssertFalse(PolishGuard.isPlausible(padded, polishOf: dictation))
    }

    func testAcceptsAnyPolishOfEmptyInput() {
        XCTAssertTrue(PolishGuard.isPlausible("Something", polishOf: ""))
    }

    func testTranslationMustKeepVerbatimTermsAndNumbers() {
        let original = "मैं AirScribe में 25 शब्द बोलता हूँ"
        XCTAssertTrue(
            PolishGuard.isPlausibleTranslation("I speak 25 words in AirScribe", of: original)
        )
        XCTAssertFalse(
            PolishGuard.isPlausibleTranslation("I speak twenty five words in the app", of: original)
        )
    }
}
