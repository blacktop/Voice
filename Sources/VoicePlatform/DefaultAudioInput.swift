import CoreAudio
import Foundation

public struct DefaultAudioInputDescription: Equatable, Sendable {
    public let name: String
    public let isBluetooth: Bool

    public init(name: String, isBluetooth: Bool) {
        self.name = name
        self.isBluetooth = isBluetooth
    }
}

/// Read-only reporting for the system-selected input. Voice deliberately does
/// not switch the default device or maintain a competing microphone preference.
public enum DefaultAudioInput {
    public static func current() -> DefaultAudioInputDescription? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        let name =
            stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName
            ) ?? "System default input"
        let transport = uint32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType
        )
        return DefaultAudioInputDescription(
            name: name,
            isBluetooth: transport.map(isBluetoothTransport) ?? false
        )
    }

    static func isBluetoothTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Reports every system default-input change for the life of the process.
    /// Without this the reported device only refreshes when Voice is
    /// reactivated, so unplugging a headset while Settings is open leaves a
    /// stale device name and a stale Bluetooth warning on screen.
    public static func observeChanges(_ onChange: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { _, _ in
            onChange()
        }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &deviceID
            ) == noErr,
            deviceID != kAudioObjectUnknown
        else {
            return nil
        }
        return deviceID
    }

    private static func uint32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr
        else {
            return nil
        }
        return value
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr
        else {
            return nil
        }
        // kAudioObjectPropertyName is returned +1: "The caller is responsible
        // for releasing the returned CFObject" (AudioHardware.h).
        guard let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
