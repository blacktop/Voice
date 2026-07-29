import AppKit
import ApplicationServices
import Foundation

public enum TargetInjectionError: LocalizedError, Sendable {
    case accessibilityPermissionRequired
    case focusedApplicationUnavailable
    case focusedElementUnavailable
    case targetChanged
    case targetChangedDuringInsertion
    case insertionInterrupted
    case insertionFailed(AXError)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "Accessibility permission is required to insert dictated text."
        case .focusedApplicationUnavailable:
            "Voice could not identify the focused application."
        case .focusedElementUnavailable:
            "Voice could not identify the focused text field."
        case .targetChanged:
            "The original text field is no longer available; nothing was inserted."
        case .targetChangedDuringInsertion:
            "The original text field lost focus during insertion; Voice stopped, but may have inserted a prefix."
        case .insertionInterrupted:
            "Text insertion was interrupted after a prefix was inserted."
        case .insertionFailed(let error):
            "The target rejected text insertion (AX error \(error.rawValue))."
        }
    }
}

public struct InputTarget: @unchecked Sendable {
    public let pid: pid_t
    fileprivate let element: AXUIElement
    fileprivate let bundleIdentifier: String?
}

enum TextInsertionCompatibilityPolicy {
    static func allowsUnicodeEventFallback(
        manualFallbackEnabled: Bool,
        bundleIdentifier: String?
    ) -> Bool {
        if manualFallbackEnabled {
            return true
        }
        switch bundleIdentifier {
        case "com.cmuxterm.app",
            "com.mitchellh.ghostty":
            return true
        default:
            return false
        }
    }
}

enum UnicodeEventPayloadPlan {
    static let maximumUTF16UnitsPerEvent = 20

    /// Removes line-break runs from process-targeted key events. A Unicode
    /// newline can be interpreted as Return by a terminal and execute input.
    static func sanitizedText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Returns one complete extended grapheme per event. Although CoreGraphics
    /// accepts up to 20 UTF-16 units, terminal hosts can drop or scramble a
    /// multi-character payload. A grapheme larger than the event budget fails
    /// the entire plan so callers never post partial text.
    static func chunks(
        for text: String,
        maximumUTF16Units: Int = maximumUTF16UnitsPerEvent
    ) -> [[UInt16]]? {
        guard maximumUTF16Units > 0 else { return nil }

        let safeText = sanitizedText(text)
        var chunks: [[UInt16]] = []
        chunks.reserveCapacity(safeText.count)
        for character in safeText {
            let units = Array(String(character).utf16)
            guard units.count <= maximumUTF16Units else { return nil }
            chunks.append(units)
        }
        return chunks
    }
}

@MainActor
enum VerifiedChunkDispatcher {
    static func dispatch<Chunk>(
        _ chunks: [Chunk],
        verifyTarget: () throws -> Void,
        postChunk: (Chunk) -> Void,
        pauseBetweenChunks: () async throws -> Void = {}
    ) async throws {
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            try verifyTarget()
            postChunk(chunk)
            if index + 1 < chunks.count {
                try await pauseBetweenChunks()
            }
        }
    }
}

public protocol TargetInjecting: Sendable {
    @MainActor func captureTarget() throws -> InputTarget
    @MainActor func insert(_ text: String, into target: InputTarget) async throws
}

/// Captures the Accessibility element focused at hotkey-down. Direct AX
/// insertion targets that element; compatibility events are process-targeted
/// and therefore use fail-closed focus checks immediately before delivery.
@MainActor
public final class AccessibilityTargetInjector: TargetInjecting {
    private struct UnicodeEventPair {
        let down: CGEvent
        let up: CGEvent
    }

    private let allowClipboardFallback: Bool
    private var allowUnicodeEventFallback: Bool

    public init(
        allowUnicodeEventFallback: Bool = false,
        allowClipboardFallback: Bool = false
    ) {
        self.allowUnicodeEventFallback = allowUnicodeEventFallback
        self.allowClipboardFallback = allowClipboardFallback
    }

    public func setUnicodeEventFallbackEnabled(_ enabled: Bool) {
        allowUnicodeEventFallback = enabled
    }

    public func captureTarget() throws -> InputTarget {
        guard VoicePermissions.hasAccessibilityAccess(prompt: true) else {
            throw TargetInjectionError.accessibilityPermissionRequired
        }
        let system = AXUIElementCreateSystemWide()
        guard
            let application = Self.elementAttribute(
                kAXFocusedApplicationAttribute,
                from: system
            )
        else {
            throw TargetInjectionError.focusedApplicationUnavailable
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success, pid != 0 else {
            throw TargetInjectionError.focusedApplicationUnavailable
        }
        guard
            let element = Self.elementAttribute(
                kAXFocusedUIElementAttribute,
                from: application
            )
        else {
            throw TargetInjectionError.focusedElementUnavailable
        }
        let bundleIdentifier = NSRunningApplication(
            processIdentifier: pid
        )?.bundleIdentifier
        return InputTarget(
            pid: pid,
            element: element,
            bundleIdentifier: bundleIdentifier
        )
    }

    public func insert(_ text: String, into target: InputTarget) async throws {
        guard !text.isEmpty else { return }
        try verifyStillFocused(target)

        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            target.element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        if settableStatus == .success, settable.boolValue {
            let result = AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if result == .success {
                return
            }
        }

        let unicodeFallbackAllowed =
            TextInsertionCompatibilityPolicy
            .allowsUnicodeEventFallback(
                manualFallbackEnabled: allowUnicodeEventFallback,
                bundleIdentifier: target.bundleIdentifier
            )
        guard unicodeFallbackAllowed else {
            throw TargetInjectionError.insertionFailed(.attributeUnsupported)
        }
        let compatibilityText = UnicodeEventPayloadPlan.sanitizedText(text)
        if compatibilityText.isEmpty {
            return
        }
        if try await postUnicode(compatibilityText, into: target) {
            return
        }

        guard allowClipboardFallback else {
            throw TargetInjectionError.insertionFailed(.cannotComplete)
        }
        try await paste(compatibilityText, into: target)
    }

    private func verifyStillFocused(_ target: InputTarget) throws {
        guard let application = NSRunningApplication(processIdentifier: target.pid),
            !application.isTerminated
        else {
            throw TargetInjectionError.targetChanged
        }

        let system = AXUIElementCreateSystemWide()
        guard
            let focusedApplication = Self.elementAttribute(
                kAXFocusedApplicationAttribute,
                from: system
            )
        else {
            throw TargetInjectionError.targetChanged
        }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedApplication, &focusedPID) == .success,
            focusedPID == target.pid
        else {
            throw TargetInjectionError.targetChanged
        }
        guard
            let focused = Self.elementAttribute(
                kAXFocusedUIElementAttribute,
                from: focusedApplication
            ), CFEqual(focused, target.element)
        else {
            throw TargetInjectionError.targetChanged
        }
    }

    private func paste(_ text: String, into target: InputTarget) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        defer { snapshot.restore(to: pasteboard) }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TargetInjectionError.insertionFailed(.cannotComplete)
        }
        try verifyStillFocused(target)
        guard Self.postKey(code: 9, modifiers: .maskCommand, to: target.pid) else {
            throw TargetInjectionError.insertionFailed(.cannotComplete)
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func postUnicode(_ text: String, into target: InputTarget) async throws -> Bool {
        guard let chunks = UnicodeEventPayloadPlan.chunks(for: text),
            let source = CGEventSource(stateID: .hidSystemState),
            let eventPairs = Self.makeEventPairs(for: chunks, source: source)
        else {
            return false
        }

        var postedAny = false
        do {
            try await VerifiedChunkDispatcher.dispatch(
                eventPairs,
                verifyTarget: { try verifyStillFocused(target) },
                postChunk: { pair in
                    pair.down.postToPid(target.pid)
                    pair.up.postToPid(target.pid)
                    postedAny = true
                },
                pauseBetweenChunks: {
                    // Roughly 500 graphemes/second remains effectively instant
                    // for dictation while giving terminal event loops a chance
                    // to consume each payload in order.
                    try await Task.sleep(for: .milliseconds(2))
                }
            )
        } catch TargetInjectionError.targetChanged where postedAny {
            throw TargetInjectionError.targetChangedDuringInsertion
        } catch is CancellationError where postedAny {
            throw TargetInjectionError.insertionInterrupted
        }
        return true
    }

    private static func makeEventPairs(
        for chunks: [[UInt16]],
        source: CGEventSource
    ) -> [UnicodeEventPair]? {
        var pairs: [UnicodeEventPair] = []
        pairs.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard
                let down = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: true
                ),
                let up = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: false
                )
            else {
                return nil
            }
            // Fresh keyboard events inherit the source's live modifier state; a
            // physically held modifier (Shift from the polish chord, Control)
            // must not turn a text chunk into a control sequence in the target.
            Self.clearInheritedModifiers(on: down)
            Self.clearInheritedModifiers(on: up)
            var encoded = false
            chunk.withUnsafeBufferPointer { pointer in
                guard let address = pointer.baseAddress else { return }
                down.keyboardSetUnicodeString(
                    stringLength: chunk.count,
                    unicodeString: address
                )
                up.keyboardSetUnicodeString(
                    stringLength: chunk.count,
                    unicodeString: address
                )
                encoded = true
            }
            guard encoded else { return nil }
            pairs.append(UnicodeEventPair(down: down, up: up))
        }
        return pairs
    }

    static func clearInheritedModifiers(on event: CGEvent) {
        event.flags = []
    }

    private static func postKey(
        code: CGKeyCode,
        modifiers: CGEventFlags,
        to pid: pid_t
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: code,
                keyDown: true
            ),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: code,
                keyDown: false
            )
        else { return false }
        down.flags = modifiers
        up.flags = modifiers
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}

@MainActor
private struct PasteboardSnapshot {
    private struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(
                values: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.values {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
