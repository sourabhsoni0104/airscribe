import XCTest
@testable import AirScribe

final class AssistantEngineTests: XCTestCase {
    private let engine = AssistantEngine()

    func testLongWakePhraseExtractsCommand() {
        XCTAssertEqual(
            engine.invocation(in: "Hey AirScribe, make that formal"),
            AssistantInvocation(command: "make that formal")
        )
    }

    func testShortWakePhraseInvokesAssistant() {
        XCTAssertEqual(
            engine.invocation(in: "AirScribe summarize this"),
            AssistantInvocation(command: "summarize this")
        )
        XCTAssertEqual(
            engine.invocation(in: "Airscibe rewrite this"),
            AssistantInvocation(command: "rewrite this")
        )
    }

    func testCommonWakePhraseTranscriptionVariants() {
        XCTAssertEqual(
            engine.invocation(in: "Hey air stripe, summarize this"),
            AssistantInvocation(command: "summarize this")
        )
        XCTAssertEqual(
            engine.invocation(in: "Hey, a scribe: make this concise"),
            AssistantInvocation(command: "make this concise")
        )
        XCTAssertEqual(
            engine.invocation(in: "Hey air scrub summarize this"),
            AssistantInvocation(command: "summarize this")
        )
        XCTAssertEqual(
            engine.invocation(in: "Hey airstrike rewrite this"),
            AssistantInvocation(command: "rewrite this")
        )
    }

    func testNormalDictationDoesNotTriggerAssistant() {
        XCTAssertNil(engine.invocation(in: "Please ask the team for an update."))
        XCTAssertNil(engine.invocation(in: "How should we approach this?"))
    }

    func testEverydayUseOfScribeIsDictatedNotInvoked() {
        // "Scribe" and "a scribe" are ordinary English; only "hey" promotes them
        // to the wake word.
        XCTAssertNil(engine.invocation(in: "Scribe the meeting notes for me"))
        XCTAssertNil(engine.invocation(in: "A scribe recorded the proceedings"))
        XCTAssertNil(engine.invocation(in: "Scribes were common in that period"))
        XCTAssertEqual(
            engine.invocation(in: "Hey scribe, make this concise"),
            AssistantInvocation(command: "make this concise")
        )
    }

    func testQuestionDetectionKeepsQuestionsAsDictation() {
        XCTAssertTrue(engine.isLikelyQuestion("How should we approach this"))
        XCTAssertTrue(engine.isLikelyQuestion("Could you send the notes?"))
        XCTAssertFalse(engine.isLikelyQuestion("Please send the notes"))
    }
}
