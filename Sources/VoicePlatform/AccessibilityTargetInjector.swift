import AppKit
import ApplicationServices
import Foundation
import os

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
    fileprivate let window: AXUIElement?
    fileprivate let fingerprint: TargetFingerprint
}

/// Identity-independent description of a focused control. Some hosts (Zed's
/// AccessKit tree, for one) hand out a fresh accessibility element for the same
/// text view whenever their tree updates, so `CFEqual` on the element alone
/// reports a focus change while the caret never moved. Matching on role and an
/// overlapping on-screen frame inside the same window identifies the same
/// control without depending on object identity. Overlap rather than equality
/// lets an input box grow as text arrives.
struct TargetFingerprint: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let frame: CGRect?

    func matches(_ other: TargetFingerprint) -> Bool {
        guard let role, role == other.role, subrole == other.subrole,
            let frame, let otherFrame = other.frame
        else {
            return false
        }
        return frame == otherFrame || frame.intersects(otherFrame)
    }
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
    private static let logger = Logger(subsystem: "io.blacktop.Voice", category: "insertion")

    /// Focus queries are re-issued a few times before they count as a focus
    /// change: a host mid-way through rebuilding its accessibility tree can
    /// answer with no value or a messaging failure for one round trip.
    private static let focusQueryAttempts = 3

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
        let fingerprint = Self.fingerprint(of: element)
        Self.logger.info(
            """
            captured target pid=\(pid) app=\(bundleIdentifier ?? "?", privacy: .public) \
            role=\(fingerprint.role ?? "?", privacy: .public) \
            frame=\(fingerprint.frame.map { "\($0)" } ?? "?", privacy: .public)
            """
        )
        return InputTarget(
            pid: pid,
            element: element,
            bundleIdentifier: bundleIdentifier,
            window: Self.elementAttribute(kAXWindowAttribute, from: element),
            fingerprint: fingerprint
        )
    }

    public func insert(_ text: String, into target: InputTarget) async throws {
        guard !text.isEmpty else { return }
        let anchor = try verifyStillFocused(target, anchor: target.element).element

        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            anchor,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        if settableStatus == .success, settable.boolValue {
            let result = AXUIElementSetAttributeValue(
                anchor,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if result == .success {
                Self.logger.info("inserted \(text.count) characters via AXSelectedText")
                return
            }
            Self.logger.notice("AXSelectedText insertion failed: AXError \(result.rawValue)")
        } else {
            Self.logger.notice(
                """
                AXSelectedText not settable: status=\(settableStatus.rawValue) \
                settable=\(settable.boolValue)
                """
            )
        }

        let unicodeFallbackAllowed =
            TextInsertionCompatibilityPolicy
            .allowsUnicodeEventFallback(
                manualFallbackEnabled: allowUnicodeEventFallback,
                bundleIdentifier: target.bundleIdentifier
            )
        guard unicodeFallbackAllowed else {
            Self.logger.error(
                "no compatibility path for \(target.bundleIdentifier ?? "?", privacy: .public)"
            )
            throw TargetInjectionError.insertionFailed(.attributeUnsupported)
        }
        let compatibilityText = UnicodeEventPayloadPlan.sanitizedText(text)
        if compatibilityText.isEmpty {
            return
        }
        if try await postUnicode(compatibilityText, into: target, anchor: anchor) {
            return
        }

        guard allowClipboardFallback else {
            Self.logger.error("unicode events could not be built and clipboard fallback is off")
            throw TargetInjectionError.insertionFailed(.cannotComplete)
        }
        try await paste(compatibilityText, into: target, anchor: anchor)
    }

    private struct VerifiedFocus {
        let element: AXUIElement
        let reanchored: Bool
    }

    /// Confirms the captured target still owns keyboard focus. `anchor` is the
    /// most recent element known to be the target; when the host has replaced
    /// the element object but the fingerprint still matches, the fresh element
    /// is returned so later checks compare identity cheaply again.
    private func verifyStillFocused(
        _ target: InputTarget,
        anchor: AXUIElement
    ) throws -> VerifiedFocus {
        // Liveness is proven by the focused-application pid comparison below.
        // `NSRunningApplication(processIdentifier:)` was used here before and
        // returned nil for a running, frontmost process mid-insertion; it is a
        // LaunchServices lookup, not a kernel one, and must not gate delivery.
        let system = AXUIElementCreateSystemWide()
        let focusedApplication = Self.elementAttribute(
            kAXFocusedApplicationAttribute,
            from: system,
            attempts: Self.focusQueryAttempts
        )
        guard let focusedApplication = focusedApplication.element else {
            Self.logger.error(
                "focused application query failed: AXError \(focusedApplication.error.rawValue)"
            )
            throw TargetInjectionError.targetChanged
        }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedApplication, &focusedPID) == .success,
            focusedPID == target.pid
        else {
            let name = NSRunningApplication(processIdentifier: focusedPID)?.bundleIdentifier
            Self.logger.error(
                """
                focus moved from pid \(target.pid) to pid \(focusedPID) \
                (\(name ?? "?", privacy: .public))
                """
            )
            throw TargetInjectionError.targetChanged
        }
        let focused = Self.elementAttribute(
            kAXFocusedUIElementAttribute,
            from: focusedApplication,
            attempts: Self.focusQueryAttempts
        )
        guard let focused = focused.element else {
            Self.logger.error(
                "focused element query failed: AXError \(focused.error.rawValue)"
            )
            throw TargetInjectionError.targetChanged
        }
        if CFEqual(focused, anchor) {
            return VerifiedFocus(element: anchor, reanchored: false)
        }
        let fingerprint = Self.fingerprint(of: focused)
        let sameWindow = Self.sameWindow(target.window, focused)
        guard sameWindow, fingerprint.matches(target.fingerprint) else {
            Self.logger.error(
                """
                focused element changed: sameWindow=\(sameWindow) \
                role=\(fingerprint.role ?? "?", privacy: .public) \
                frame=\(fingerprint.frame.map { "\($0)" } ?? "?", privacy: .public) \
                captured role=\(target.fingerprint.role ?? "?", privacy: .public) \
                frame=\(target.fingerprint.frame.map { "\($0)" } ?? "?", privacy: .public)
                """
            )
            throw TargetInjectionError.targetChanged
        }
        Self.logger.debug("focused element identity changed; fingerprint matched, re-anchoring")
        return VerifiedFocus(element: focused, reanchored: true)
    }

    private static func sameWindow(_ window: AXUIElement?, _ element: AXUIElement) -> Bool {
        guard let window,
            let current = elementAttribute(kAXWindowAttribute, from: element)
        else {
            return false
        }
        return CFEqual(window, current)
    }

    private static func fingerprint(of element: AXUIElement) -> TargetFingerprint {
        var frame: CGRect?
        if let origin = pointAttribute(kAXPositionAttribute, from: element),
            let size = sizeAttribute(kAXSizeAttribute, from: element)
        {
            frame = CGRect(origin: origin, size: size)
        }
        return TargetFingerprint(
            role: stringAttribute(kAXRoleAttribute, from: element),
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            frame: frame
        )
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else {
            return nil
        }
        return value as? String
    }

    private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let value = axValue(attribute, from: element) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        guard let value = axValue(attribute, from: element) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ attribute: String, from element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private func paste(
        _ text: String,
        into target: InputTarget,
        anchor: AXUIElement
    ) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        defer { snapshot.restore(to: pasteboard) }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TargetInjectionError.insertionFailed(.cannotComplete)
        }
        _ = try verifyStillFocused(target, anchor: anchor)
        guard Self.postKey(code: 9, modifiers: .maskCommand, to: target.pid) else {
            throw TargetInjectionError.insertionFailed(.cannotComplete)
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        elementAttribute(attribute, from: element, attempts: 1).element
    }

    private static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement,
        attempts: Int
    ) -> (element: AXUIElement?, error: AXError) {
        var error = AXError.failure
        for _ in 0..<max(attempts, 1) {
            var value: CFTypeRef?
            error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (unsafeDowncast(value, to: AXUIElement.self), .success)
            }
        }
        return (nil, error)
    }

    private func postUnicode(
        _ text: String,
        into target: InputTarget,
        anchor: AXUIElement
    ) async throws -> Bool {
        guard let chunks = UnicodeEventPayloadPlan.chunks(for: text),
            let source = CGEventSource(stateID: .hidSystemState),
            let eventPairs = Self.makeEventPairs(for: chunks, source: source)
        else {
            return false
        }

        var posted = 0
        var reanchors = 0
        var anchor = anchor
        do {
            try await VerifiedChunkDispatcher.dispatch(
                eventPairs,
                verifyTarget: {
                    let focus = try verifyStillFocused(target, anchor: anchor)
                    anchor = focus.element
                    if focus.reanchored {
                        reanchors += 1
                    }
                },
                postChunk: { pair in
                    pair.down.postToPid(target.pid)
                    pair.up.postToPid(target.pid)
                    posted += 1
                },
                pauseBetweenChunks: {
                    // Roughly 500 graphemes/second remains effectively instant
                    // for dictation while giving terminal event loops a chance
                    // to consume each payload in order.
                    try await Task.sleep(for: .milliseconds(2))
                }
            )
        } catch TargetInjectionError.targetChanged where posted > 0 {
            Self.logger.error(
                "target changed after \(posted) of \(eventPairs.count) unicode events"
            )
            throw TargetInjectionError.targetChangedDuringInsertion
        } catch is CancellationError where posted > 0 {
            Self.logger.notice("cancelled after \(posted) of \(eventPairs.count) unicode events")
            throw TargetInjectionError.insertionInterrupted
        }
        Self.logger.info(
            "posted \(posted) unicode events to pid \(target.pid); re-anchored \(reanchors) times"
        )
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
