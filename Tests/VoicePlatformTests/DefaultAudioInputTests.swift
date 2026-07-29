import CoreAudio
import XCTest

@testable import VoicePlatform

final class DefaultAudioInputTests: XCTestCase {
    func testClassifiesBluetoothTransportsWithoutTreatingBuiltInAsBluetooth() {
        XCTAssertTrue(
            DefaultAudioInput.isBluetoothTransport(
                kAudioDeviceTransportTypeBluetooth
            )
        )
        XCTAssertTrue(
            DefaultAudioInput.isBluetoothTransport(
                kAudioDeviceTransportTypeBluetoothLE
            )
        )
        XCTAssertFalse(
            DefaultAudioInput.isBluetoothTransport(
                kAudioDeviceTransportTypeBuiltIn
            )
        )
    }
}
