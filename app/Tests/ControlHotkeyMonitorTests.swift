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

    func testDoublePressWindowAllowsAnIntentionalModifierTap() {
        let state = ControlHotkeyStateMachine()
        XCTAssertGreaterThanOrEqual(state.doubleTapInterval, 0.5)
    }

    @MainActor
    func testMonitorHandlesDoubleControlPressAsHandsFreeDictation() {
        let monitor = ControlHotkeyMonitor()
        var beginCount = 0
        var endCount = 0
        monitor.onBegin = { beginCount += 1 }
        monitor.onEnd = { endCount += 1 }

        monitor.handleCGEvent(type: .flagsChanged, flags: .maskControl, keyCode: 59)
        monitor.handleCGEvent(type: .flagsChanged, flags: [], keyCode: 59)
        monitor.handleCGEvent(type: .flagsChanged, flags: .maskControl, keyCode: 59)
        monitor.handleCGEvent(type: .flagsChanged, flags: [], keyCode: 59)

        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(endCount, 0)

        monitor.handleCGEvent(type: .flagsChanged, flags: .maskControl, keyCode: 59)
        XCTAssertEqual(endCount, 1)
    }
}
