import CoreGraphics
import VoiceCore
import XCTest

@testable import VoicePlatform

final class GlobalHotkeyMonitorTests: XCTestCase {
    func testLeftOptionIsIgnored() {
        var state = RightOptionHotkeyState()

        let transition = state.handle(keyCode: 58, flags: .maskAlternate)

        XCTAssertNil(transition)
        XCTAssertFalse(state.isPressed)
    }

    func testRightOptionPressAndRelease() {
        var state = RightOptionHotkeyState()

        let press = state.handle(keyCode: 61, flags: .maskAlternate)
        let release = state.handle(keyCode: 61, flags: [])

        assertPress(press, mode: .conservative)
        assertRelease(release)
        XCTAssertFalse(state.isPressed)
    }

    func testShiftBeforeRightOptionSelectsPolish() {
        var state = RightOptionHotkeyState()

        let press = state.handle(
            keyCode: 61,
            flags: [.maskAlternate, .maskShift]
        )

        assertPress(press, mode: .polish)
    }

    func testRightOptionReleaseIsDetectedWhileLeftOptionRemainsHeld() {
        var state = RightOptionHotkeyState()
        _ = state.handle(keyCode: 61, flags: .maskAlternate)

        let release = state.handle(keyCode: 61, flags: .maskAlternate)

        assertRelease(release)
        XCTAssertFalse(state.isPressed)
    }

    func testDeviceFlagsDistinguishRightOptionKeyUpFromPressWhileLeftOptionHeld() {
        var state = RightOptionHotkeyState()

        // After a missed press (state reset while the key was held), a
        // right-option key-UP arrives with .maskAlternate still set by the held
        // LEFT option. The device bits identify it as not-a-press.
        let phantom = state.handle(
            keyCode: 61,
            flags: CGEventFlags(
                rawValue: CGEventFlags.maskAlternate.rawValue | 0x20
            )
        )

        XCTAssertNil(phantom)
        XCTAssertFalse(state.isPressed)
    }

    func testDeviceFlagsTrackPressAndReleaseWhileLeftOptionHeld() {
        var state = RightOptionHotkeyState()

        let press = state.handle(
            keyCode: 61,
            flags: CGEventFlags(
                rawValue: CGEventFlags.maskAlternate.rawValue | 0x20 | 0x40
            )
        )
        let release = state.handle(
            keyCode: 61,
            flags: CGEventFlags(
                rawValue: CGEventFlags.maskAlternate.rawValue | 0x20
            )
        )

        assertPress(press, mode: .conservative)
        assertRelease(release)
        XCTAssertFalse(state.isPressed)
    }

    func testStrayReleaseAndResetDoNotEmitTransitions() {
        var state = RightOptionHotkeyState()

        XCTAssertNil(state.handle(keyCode: 61, flags: []))
        XCTAssertFalse(state.reset())
    }

    func testResetReportsAnActivePressOnce() {
        var state = RightOptionHotkeyState()
        _ = state.handle(keyCode: 61, flags: .maskAlternate)

        XCTAssertTrue(state.reset())
        XCTAssertFalse(state.reset())
        XCTAssertFalse(state.isPressed)
    }

    private func assertPress(
        _ transition: RightOptionHotkeyTransition?,
        mode expectedMode: CleanupMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .pressed(let mode) = transition else {
            XCTFail("Expected a hotkey press", file: file, line: line)
            return
        }
        XCTAssertEqual(mode.rawValue, expectedMode.rawValue, file: file, line: line)
    }

    private func assertRelease(
        _ transition: RightOptionHotkeyTransition?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .released = transition else {
            XCTFail("Expected a hotkey release", file: file, line: line)
            return
        }
    }
}
