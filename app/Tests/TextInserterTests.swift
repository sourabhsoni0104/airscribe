import XCTest
@testable import AirScribe

final class TextInserterTests: XCTestCase {
    func testRecognizesEditableTextRoles() {
        XCTAssertTrue(TextInserter.isTextInputRole(role: "AXTextField", subrole: nil))
        XCTAssertTrue(TextInserter.isTextInputRole(role: "AXTextArea", subrole: nil))
        XCTAssertTrue(TextInserter.isTextInputRole(role: "AXComboBox", subrole: nil))
        XCTAssertTrue(TextInserter.isTextInputRole(role: "AXGroup", subrole: "AXSearchField"))
    }

    func testRejectsNonTextRoles() {
        XCTAssertFalse(TextInserter.isTextInputRole(role: "AXButton", subrole: nil))
        XCTAssertFalse(TextInserter.isTextInputRole(role: "AXWindow", subrole: nil))
    }

    func testRecognizesTerminalApplications() {
        XCTAssertTrue(TextInserter.isTerminalApplication(bundleIdentifier: "com.apple.Terminal"))
        XCTAssertTrue(TextInserter.isTerminalApplication(bundleIdentifier: "com.googlecode.iterm2"))
        XCTAssertTrue(TextInserter.isTerminalApplication(bundleIdentifier: "dev.warp.Warp-Stable"))
        XCTAssertFalse(TextInserter.isTerminalApplication(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(TextInserter.isTerminalApplication(bundleIdentifier: nil))
    }

    func testTerminalTextNeverContainsCommandExecutingControlCharacters() {
        XCTAssertEqual(
            TextInserter.terminalSafeText("echo hello\nrm something\t\u{0007}done"),
            "echo hello rm something done"
        )
    }

    func testTerminalTypingChunksPreserveUnicodeCharacters() {
        let source = "नमस्ते from AirScribe 👋🏽"
        let chunks = TextInserter.terminalTypingChunks(source, maximumUTF16Count: 8)
        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 8 || $0.count == 1 })
    }

    @MainActor
    func testWritesAndReadsBackExactClipboardText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let transcript = "Text copied by AirScribe — exactly."

        XCTAssertTrue(TextInserter.write(transcript, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), transcript)
    }

    func testClipboardSnapshotAcceptsTextButRejectsBinaryPayloads() {
        XCTAssertTrue(TextInserter.isSafeTextPasteboardType(.string))
        XCTAssertTrue(TextInserter.isSafeTextPasteboardType(.html))
        XCTAssertFalse(TextInserter.isSafeTextPasteboardType(.png))
        XCTAssertFalse(TextInserter.isSafeTextPasteboardType(.fileURL))
    }

    func testFindsRecentlyPastedTextImmediatelyBeforeCaret() {
        XCTAssertEqual(
            TextInserter.pastedTextRange(
                in: "Before Open the text box. After",
                selection: NSRange(location: 25, length: 0),
                pastedText: "Open the text box."
            ),
            NSRange(location: 7, length: 18)
        )
        XCTAssertNil(
            TextInserter.pastedTextRange(
                in: "Before unrelated text",
                selection: NSRange(location: 21, length: 0),
                pastedText: "Open the text box."
            )
        )
    }

    func testExtractsCorrectedTextBetweenStableAnchors() {
        let snapshot = "Before: Open the text box. After"
        let insertionOffset = ("Before: " as NSString).length

        XCTAssertEqual(
            TextInserter.textBetweenAnchors(
                in: snapshot,
                insertionOffset: insertionOffset,
                beforeAnchor: "Before: ",
                afterAnchor: ". After",
                cursorOffset: nil
            ),
            "Open the text box"
        )
    }

    func testExtractsCorrectionFromEmptyFieldUsingCursor() {
        XCTAssertEqual(
            TextInserter.textBetweenAnchors(
                in: "text box",
                insertionOffset: 0,
                beforeAnchor: "",
                afterAnchor: "",
                cursorOffset: 8
            ),
            "text box"
        )
    }

    func testInferredInsertionBoundaryWinsOverCursorInsideCorrection() {
        let corrected = "Open the text box now."
        XCTAssertEqual(
            TextInserter.textBetweenAnchors(
                in: corrected,
                insertionOffset: 0,
                beforeAnchor: "",
                afterAnchor: "",
                inferredEndOffset: (corrected as NSString).length,
                cursorOffset: ("Open the text box" as NSString).length
            ),
            corrected
        )
    }

    func testRejectsSnapshotWhenStableAnchorDisappears() {
        XCTAssertNil(
            TextInserter.textBetweenAnchors(
                in: "Unrelated content",
                insertionOffset: 5,
                beforeAnchor: "Before",
                afterAnchor: "After",
                cursorOffset: nil
            )
        )
    }
}
