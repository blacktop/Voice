import AppKit
import CoreGraphics
import Foundation
import VoiceCore

/// The tap and all mutable state run on the main CFRunLoop. The unchecked
/// conformance documents that C callback invariant for Swift concurrency.
public final class GlobalHotkeyMonitor: @unchecked Sendable {
    public typealias PressHandler = @Sendable (UInt64, CleanupMode) -> Void
    public typealias ReleaseHandler = @Sendable (UInt64) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkeyState = RightOptionHotkeyState()
    private var eventSequence: UInt64 = 0
    private let onPress: PressHandler
    private let onRelease: ReleaseHandler

    public init(
        onPress: @escaping PressHandler,
        onRelease: @escaping ReleaseHandler
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    deinit {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }

    /// Whether an event tap currently exists. Callers should avoid restarting a
    /// running monitor: `start()` tears the tap down first, which synthesizes a
    /// release for any in-progress hold.
    public var isRunning: Bool {
        eventTap != nil
    }

    @discardableResult
    public func start() -> Bool {
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: voiceHotkeyCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if hotkeyState.reset() {
            eventSequence &+= 1
            onRelease(eventSequence)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if hotkeyState.reset() {
                eventSequence &+= 1
                onRelease(eventSequence)
            }
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard type == .flagsChanged else { return }
        let transition = hotkeyState.handle(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags
        )
        switch transition {
        case .pressed(let mode):
            eventSequence &+= 1
            onPress(eventSequence, mode)
        case .released:
            eventSequence &+= 1
            onRelease(eventSequence)
        case nil:
            break
        }
    }
}

enum RightOptionHotkeyTransition {
    case pressed(CleanupMode)
    case released
}

struct RightOptionHotkeyState {
    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK from IOLLEvent.h.
    private static let deviceLeftOptionMask: UInt64 = 0x20
    private static let deviceRightOptionMask: UInt64 = 0x40

    private(set) var isPressed = false

    mutating func handle(
        keyCode: Int64,
        flags: CGEventFlags
    ) -> RightOptionHotkeyTransition? {
        guard keyCode == 61 else { return nil }
        // .maskAlternate stays set while EITHER Option key is held, so toggling
        // on it misclassifies a right-option key-up as a press after a missed
        // event (tap rebuild, disable timeout) when the left key is also down.
        // The device-specific right-Option bit tracks the physical key and
        // self-corrects; keyboards that report no device bits at all keep the
        // legacy toggle.
        let rightOptionDown: Bool
        if !flags.contains(.maskAlternate) {
            rightOptionDown = false
        } else if flags.rawValue
            & (Self.deviceLeftOptionMask | Self.deviceRightOptionMask) != 0
        {
            rightOptionDown = flags.rawValue & Self.deviceRightOptionMask != 0
        } else {
            rightOptionDown = !isPressed
        }

        guard rightOptionDown != isPressed else { return nil }
        isPressed = rightOptionDown
        if rightOptionDown {
            return .pressed(flags.contains(.maskShift) ? .polish : .conservative)
        }
        return .released
    }

    mutating func reset() -> Bool {
        defer { isPressed = false }
        return isPressed
    }
}

private func voiceHotkeyCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    dispatchPrecondition(condition: .onQueue(.main))
    let monitor = Unmanaged<GlobalHotkeyMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    monitor.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
