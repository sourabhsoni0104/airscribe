import XCTest
@testable import AirScribe

final class BasicTextEnhancerTests: XCTestCase {
    private let enhancer = BasicTextEnhancer()
    private let correctionLearner = CorrectionLearner()

    func testRemovesFillersAndExpandsYou() {
        let input = "hey um can u help me with like writing an email to my boss about um vacation"
        let output = enhancer.enhance(input, mode: .email)
        XCTAssertEqual(output, "Hey, can you help me with writing an email to my boss about vacation?")
    }

    func testDoesNotRemoveMeaningfulLike() {
        let output = enhancer.enhance("I like local software", mode: .general)
        XCTAssertEqual(output, "I like local software.")
    }

    func testRemovesFumblesAndKeepsTheExplicitCorrection() {
        XCTAssertEqual(
            enhancer.enhance("the command is port, I mean put", mode: .general),
            "The command is put."
        )
        XCTAssertEqual(
            enhancer.enhance("I I need the final version", mode: .general),
            "I need the final version."
        )
        XCTAssertEqual(
            enhancer.enhance("use port but I meant put for the command", mode: .general),
            "Use put for the command."
        )
    }

    func testSpokenFullStopUsesGrammaticalContext() {
        XCTAssertEqual(
            enhancer.enhance("send it now full stop start the next item", mode: .general),
            "Send it now. Start the next item."
        )
        XCTAssertEqual(
            enhancer.enhance("send it now full stop then we can leave", mode: .general),
            "Send it now. Then we can leave."
        )
        XCTAssertEqual(
            enhancer.enhance("print the words full stop", mode: .general),
            "Print the words full stop."
        )
        XCTAssertEqual(
            enhancer.enhance("a full stop is different from a comma", mode: .general),
            "A full stop is different from a comma."
        )
        XCTAssertEqual(
            enhancer.enhance("I said full stop but it inserted a symbol", mode: .general),
            "I said full stop but it inserted a symbol."
        )
        XCTAssertEqual(
            enhancer.enhance("I want the word full stop to be printed", mode: .general),
            "I want the word full stop to be printed."
        )
        XCTAssertEqual(
            enhancer.enhance("full stop can also be written as a period", mode: .general),
            "Full stop can also be written as a period."
        )
        XCTAssertEqual(
            enhancer.enhance("what is full stop", mode: .general),
            "What is full stop?"
        )
        XCTAssertEqual(
            enhancer.enhance("full stop", mode: .general),
            "Full stop."
        )
        XCTAssertEqual(
            enhancer.enhance("send it now full stop", mode: .general),
            "Send it now."
        )
    }

    func testPreservesVocabularyCapitalization() {
        let output = enhancer.enhance("airscribe works offline", mode: .general, vocabulary: ["AirScribe"])
        XCTAssertEqual(output, "AirScribe works offline.")
    }

    func testNearbyContextRepairsSplitCompoundTerms() {
        let output = enhancer.enhance(
            "use the coral lip stick shade",
            mode: .general,
            vocabulary: ["lipstick"]
        )
        XCTAssertEqual(output, "Use the coral lipstick shade.")
    }

    func testResolvesOnesAndOnceFromContext() {
        XCTAssertEqual(
            enhancer.enhance("use the once on the left", mode: .general),
            "Use the ones on the left."
        )
        XCTAssertEqual(
            enhancer.enhance("for ones send it early", mode: .general),
            "For once send it early."
        )
        XCTAssertEqual(
            enhancer.enhance("ones a week is enough", mode: .general),
            "Once a week is enough."
        )
    }

    func testResolvesSimilarHomophonesOnlyInClearGrammar() {
        XCTAssertEqual(enhancer.enhance("your right about that", mode: .general), "You're right about that.")
        XCTAssertEqual(enhancer.enhance("their is another option", mode: .general), "There is another option.")
        XCTAssertEqual(enhancer.enhance("it is to late", mode: .general), "It is too late.")
        XCTAssertEqual(enhancer.enhance("we should of waited", mode: .general), "We should have waited.")
    }

    func testLearnsSingleWordCorrectionAndVocabulary() {
        let result = correctionLearner.learn(
            from: "Please ask Jon about deployment.",
            to: "Please ask John about deployment."
        )
        XCTAssertEqual(
            result,
            CorrectionLearningResult(replacements: ["jon": "John"], vocabulary: ["John"])
        )
        XCTAssertEqual(
            enhancer.enhance(
                "please ask jon tomorrow",
                mode: .general,
                learnedCorrections: result?.replacements ?? [:]
            ),
            "Please ask John tomorrow."
        )
    }

    func testLearnsOneWordToTwoWordCorrection() {
        let result = correctionLearner.learn(
            from: "Open the textbook.",
            to: "Open the text box."
        )

        XCTAssertEqual(result?.replacements["textbook"], "text box")
        XCTAssertEqual(result?.vocabulary, [])
        XCTAssertEqual(
            enhancer.enhance(
                "select the textbook",
                mode: .general,
                learnedCorrections: result?.replacements ?? [:]
            ),
            "Select the text box."
        )
    }

    func testLearnsTwoWordsAsOneWord() {
        let result = correctionLearner.learn(
            from: "Choose the coral lip stick shade.",
            to: "Choose the coral lipstick shade."
        )

        XCTAssertEqual(result?.replacements["lip stick"], "lipstick")
        XCTAssertEqual(
            enhancer.enhance(
                "use the lip stick color",
                mode: .general,
                learnedCorrections: result?.replacements ?? [:]
            ),
            "Use the lipstick color."
        )
    }

    func testLearnedPhraseMatchesFlexibleWhitespace() {
        XCTAssertEqual(
            enhancer.enhance(
                "open the text   book now",
                mode: .general,
                learnedCorrections: ["text book": "text box"]
            ),
            "Open the text box now."
        )
    }

    func testDoesNotLearnContinuedTypingOrPunctuationOnlyEdits() {
        XCTAssertNil(
            correctionLearner.learn(
                from: "Send the report.",
                to: "Send the report tomorrow."
            )
        )
        XCTAssertNil(
            correctionLearner.learn(
                from: "Send the report.",
                to: "Send the report!"
            )
        )
    }

    func testIgnoresCasingOnlyCorrectionsForCommonWords() {
        XCTAssertNil(
            correctionLearner.learn(
                from: "please send the note",
                to: "Please send the note"
            )
        )

        XCTAssertEqual(
            enhancer.enhance(
                "we saw the note",
                mode: .general,
                learnedCorrections: ["the": "The"]
            ),
            "We saw the note."
        )
    }

    func testLearnsNewTermButRejectsUnrelatedRewrite() {
        XCTAssertEqual(
            correctionLearner.learn(
                from: "Deploy the service today.",
                to: "Deploy the Kubernetes service today."
            )?.vocabulary,
            ["Kubernetes"]
        )
        XCTAssertNil(
            correctionLearner.learn(
                from: "Send the note.",
                to: "This is completely unrelated content with many different words."
            )
        )
    }

    func testAddsQuotationMarksAroundDirectSpeech() {
        XCTAssertEqual(
            enhancer.enhance("I said do you see any…", mode: .general),
            "I said, “Do you see any…”"
        )
        XCTAssertEqual(
            enhancer.enhance("I asked where are the files?", mode: .general),
            "I asked, “Where are the files?”"
        )
    }

    func testDoesNotQuoteIndirectSpeech() {
        XCTAssertEqual(
            enhancer.enhance("I said that we should leave", mode: .general),
            "I said that we should leave."
        )
    }

    func testConvertsSpokenSymbolNames() {
        XCTAssertEqual(
            enhancer.enhance(
                "email me at sourabh at the rate symbol example dot symbol com",
                mode: .general
            ),
            "Email me at sourabh@example.com."
        )
        XCTAssertEqual(
            enhancer.enhance("use hash symbol AirScribe", mode: .general),
            "Use #AirScribe."
        )
    }

    func testEmailModeDoesNotInventBoilerplate() {
        XCTAssertEqual(
            enhancer.enhance("can we meet today", mode: .email),
            "Can we meet today?"
        )
    }

    func testEmailModePreservesExplicitGreetingAndSignOff() {
        XCTAssertEqual(
            enhancer.enhance("Hi Alex, can we meet today? Thanks,", mode: .email),
            "Hi Alex, can we meet today? Thanks,"
        )
    }

    func testFullEnhancerPreservesParagraphBreaks() {
        XCTAssertEqual(
            enhancer.enhance("first paragraph.\n\nsecond paragraph.", mode: .general),
            "First paragraph.\n\nsecond paragraph."
        )
    }
}

final class PauseAwarePunctuationTests: XCTestCase {
    func testTransfersSemanticPunctuationFromTimingGuide() {
        let result = PauseAwarePunctuation.apply(
            to: "hello everyone how are you today I am doing well",
            using: "Hello, everyone. How are you today? I am doing well.",
            timings: []
        )
        XCTAssertEqual(result, "Hello, everyone. How are you today? I am doing well.")
    }

    func testLongPauseCreatesSentenceBoundary() {
        let words = ["I", "finished", "the", "draft", "please", "review", "it"]
        let timings = words.enumerated().map { index, word in
            let start = index < 4 ? Double(index) * 0.25 : 2.4 + Double(index - 4) * 0.25
            return TranscribedWordTiming(text: word, startTime: start, endTime: start + 0.18)
        }
        let result = PauseAwarePunctuation.apply(
            to: "i finished the draft please review it",
            using: "I finished the draft please review it",
            timings: timings
        )
        XCTAssertEqual(result, "I finished the draft. Please review it")
    }

    func testShortPauseDoesNotSplitIncompletePhrase() {
        let timings = [
            TranscribedWordTiming(text: "send", startTime: 0, endTime: 0.2),
            TranscribedWordTiming(text: "the", startTime: 0.25, endTime: 0.45),
            TranscribedWordTiming(text: "message", startTime: 1.1, endTime: 1.35)
        ]
        let result = PauseAwarePunctuation.apply(
            to: "send the message",
            using: "Send the message",
            timings: timings
        )
        XCTAssertEqual(result, "Send the message")
    }

    func testAbruptStopUsesEllipsisForHangingQuestion() {
        let timings = [
            TranscribedWordTiming(text: "do", startTime: 0, endTime: 0.18),
            TranscribedWordTiming(text: "you", startTime: 0.22, endTime: 0.38),
            TranscribedWordTiming(text: "see", startTime: 0.42, endTime: 0.6),
            TranscribedWordTiming(text: "any", startTime: 0.64, endTime: 0.82)
        ]
        let result = PauseAwarePunctuation.apply(
            to: "do you see any",
            using: "Do you see any?",
            timings: timings,
            audioDuration: 0.94
        )
        XCTAssertEqual(result, "Do you see any…")
    }

    func testPreservesParagraphsQuotesAndParentheses() {
        let result = PauseAwarePunctuation.apply(
            to: "he said “hello world”\n\n(then we left)",
            using: "He said, “hello world.”\n\n(Then we left.)",
            timings: []
        )
        XCTAssertEqual(result, "He said, “hello world.”\n\n(Then we left.)")
    }

    func testPreservesExistingExpressivePunctuation() {
        let result = PauseAwarePunctuation.apply(
            to: "wait—what?! Really?",
            using: "wait what really",
            timings: []
        )
        XCTAssertEqual(result, "Wait—what?! Really?")
    }

    func testDoesNotCapitalizeAfterAbbreviations() {
        let result = PauseAwarePunctuation.apply(
            to: "we support e.g. examples and Dr. smith",
            using: "We support e.g. examples and Dr. smith",
            timings: []
        )
        XCTAssertEqual(result, "We support e.g. examples and Dr. smith")
    }

    func testLongPauseInfersQuestionBoundary() {
        let words = ["can", "you", "help", "me", "I", "found", "it"]
        let timings = words.enumerated().map { index, word in
            let start = index < 4 ? Double(index) * 0.22 : 1.85 + Double(index - 4) * 0.22
            return TranscribedWordTiming(text: word, startTime: start, endTime: start + 0.16)
        }
        let result = PauseAwarePunctuation.apply(
            to: "can you help me I found it",
            using: "can you help me I found it",
            timings: timings
        )
        XCTAssertEqual(result, "Can you help me? I found it")
    }

    func testPauseInsideSubordinateClauseUsesCommaInsteadOfPeriod() {
        let words = ["whenever", "I", "stop", "it", "adds", "punctuation"]
        let timings = words.enumerated().map { index, word in
            let start = index < 3 ? Double(index) * 0.22 : 1.75 + Double(index - 3) * 0.22
            return TranscribedWordTiming(text: word, startTime: start, endTime: start + 0.16)
        }
        let result = PauseAwarePunctuation.apply(
            to: "whenever I stop. it adds punctuation",
            using: "Whenever I stop. It adds punctuation.",
            timings: timings
        )
        XCTAssertEqual(result, "Whenever I stop, it adds punctuation.")
    }

    func testModeratePauseDoesNotBlindlyCopySystemPeriod() {
        let timings = [
            TranscribedWordTiming(text: "we", startTime: 0, endTime: 0.15),
            TranscribedWordTiming(text: "reviewed", startTime: 0.2, endTime: 0.4),
            TranscribedWordTiming(text: "the", startTime: 0.45, endTime: 0.58),
            TranscribedWordTiming(text: "proposal", startTime: 0.63, endTime: 0.84),
            TranscribedWordTiming(text: "especially", startTime: 1.44, endTime: 1.7),
            TranscribedWordTiming(text: "pricing", startTime: 1.75, endTime: 1.96),
        ]
        let result = PauseAwarePunctuation.apply(
            to: "we reviewed the proposal. especially pricing",
            using: "We reviewed the proposal. Especially pricing.",
            timings: timings
        )
        XCTAssertEqual(result, "We reviewed the proposal, especially pricing.")
    }
}

final class SpeechContextPhrasesTests: XCTestCase {
    func testContextIsSplitIntoUsableVocabularyPhrases() {
        let phrases = SpeechContextPhrases.extract(
            from: """
            Active app: Notes
            Window: Product launch
            Preferred vocabulary: AirScribe, Kubernetes
            Focused text: Pick the coral lipstick shade for Priyanka.
            """
        )

        XCTAssertTrue(phrases.contains("AirScribe"))
        XCTAssertTrue(phrases.contains("Kubernetes"))
        XCTAssertTrue(phrases.contains("lipstick"))
        XCTAssertTrue(phrases.contains("Priyanka"))
        XCTAssertFalse(phrases.contains { $0.contains("\n") })
    }
}
