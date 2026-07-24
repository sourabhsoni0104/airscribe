import XCTest
@testable import AirScribe

final class ControlHotkeyMonitorTests: XCTestCase {
    func testHoldModeBeginsOnFirstPressAndEndsAfterRelease() {
        var state = ControlHotkeyStateMachine()

        XCTAssertEqual(state.handleControlTransition(isDown: true), .begin)
        XCTAssertTrue(state.dictationIsActive)

        XCTAssertEqual(state.handleControlTransition(isDown: false), .scheduleEnd)
        XCTAssertTrue(state.finishListeningIfPendingEndStillValid())
        XCTAssertFalse(state.dictationIsActive)
    }

    func testDoublePressLatchesAndStopsOnNextPress() {
        var state = ControlHotkeyStateMachine()

        XCTAssertEqual(state.handleControlTransition(isDown: true), .begin)
        XCTAssertEqual(state.handleControlTransition(isDown: false), .scheduleEnd)
        XCTAssertEqual(state.handleControlTransition(isDown: true), .latch)
        XCTAssertTrue(state.dictationIsActive)
        XCTAssertTrue(state.latched)

        XCTAssertNil(state.handleControlTransition(isDown: false))
        XCTAssertEqual(state.handleControlTransition(isDown: true), .end)
        XCTAssertFalse(state.dictationIsActive)
        XCTAssertFalse(state.latched)
    }
}
