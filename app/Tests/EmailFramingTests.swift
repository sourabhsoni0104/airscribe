import XCTest
@testable import AirScribe

final class EmailFramingTests: XCTestCase {
    func testRecognisesFormalPhrasing() {
        XCTAssertEqual(
            EmailFraming.register(of: "Kindly do the needful at your earliest convenience."),
            .formal
        )
        XCTAssertEqual(
            EmailFraming.register(of: "I am writing to request an extension on the submission."),
            .formal
        )
        XCTAssertEqual(
            EmailFraming.register(of: "With reference to your mail, please find the report attached."),
            .formal
        )
    }

    func testRecognisesCasualPhrasing() {
        XCTAssertEqual(EmailFraming.register(of: "hey, quick question about tomorrow"), .informal)
        XCTAssertEqual(EmailFraming.register(of: "thanks for the heads up, let's catch up"), .informal)
        XCTAssertEqual(EmailFraming.register(of: "I'll ping you when it's done"), .informal)
    }

    func testTreatsLongFormalProseWithoutMarkersAsFormal() {
        let body = """
            The committee reviewed the proposal in detail and concluded that the current \
            timeline cannot accommodate the additional scope without a corresponding \
            revision to the agreed budget, which requires approval from the finance \
            department before any further work begins on the second phase of the \
            project as it was originally described to the board.
            """
        XCTAssertEqual(EmailFraming.register(of: body), .formal)
    }

    func testFallsBackToInformalWhenUnsure() {
        // "Hi" reads fine in a formal thread; "Dear Sir/Madam" on a quick note
        // to a colleague does not, so ambiguity resolves the safer way.
        XCTAssertEqual(EmailFraming.register(of: "The meeting is at four."), .informal)
    }

    func testDetectsGreetingsTheSpeakerDictated() {
        XCTAssertTrue(EmailFraming.hasGreeting("Hi Alex, are you free?"))
        XCTAssertTrue(EmailFraming.hasGreeting("Dear Dr Rao, thank you."))
        XCTAssertTrue(EmailFraming.hasGreeting("Respected Sir, I write regarding"))
        XCTAssertTrue(EmailFraming.hasGreeting("Good morning, quick update."))
        XCTAssertFalse(EmailFraming.hasGreeting("Can we meet today?"))
        XCTAssertFalse(EmailFraming.hasGreeting("Highlight the second row."))
    }

    func testDetectsSignOffsTheSpeakerDictated() {
        XCTAssertTrue(EmailFraming.hasSignOff("Please review it. Thanks,"))
        XCTAssertTrue(EmailFraming.hasSignOff("See you then.\n\nBest regards"))
        XCTAssertTrue(EmailFraming.hasSignOff("I appreciate it. Yours sincerely,"))
        XCTAssertTrue(EmailFraming.hasSignOff("Thanking you,"))
        XCTAssertFalse(EmailFraming.hasSignOff("Thanks for sending the file over."))
        XCTAssertFalse(EmailFraming.hasSignOff("Can we meet today?"))
    }

    func testFramesBothEnds() {
        XCTAssertEqual(
            EmailFraming.framed("Can we meet today?"),
            "Hi,\n\nCan we meet today?\n\nRegards,"
        )
    }

    func testLeavesAFullyWrittenMessageAlone() {
        let message = "Hi Alex,\n\nCan we meet today?\n\nThanks,"
        XCTAssertEqual(EmailFraming.framed(message), message)
    }

    func testDoesNotDuplicateAGreetingOrSignOff() {
        let framed = EmailFraming.framed("Hi Alex, can we meet today?")
        XCTAssertEqual(framed.components(separatedBy: "Hi").count - 1, 1)
        XCTAssertTrue(framed.hasSuffix("Regards,"))
    }

    func testEmptyBodyIsUntouched() {
        XCTAssertEqual(EmailFraming.framed("   "), "   ")
    }
}
