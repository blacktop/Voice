import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation

public enum VoicePermissions {
    public static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    public static func hasAccessibilityAccess(prompt: Bool) -> Bool {
        // The exported C global is annotated as mutable and therefore rejected
        // by Swift 6 strict concurrency. Its documented CFString value is stable.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    public static func requestInputMonitoringAccess() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }
        return CGRequestListenEventAccess()
    }
}
