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

    @MainActor
    func testWritesAndReadsBackExactClipboardText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let transcript = "Text copied by AirScribe — exactly."

        XCTAssertTrue(TextInserter.write(transcript, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), transcript)
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
