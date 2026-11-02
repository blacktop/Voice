import ApplicationServices
import Foundation

enum AccessibilityPasteCommandError: LocalizedError {
    case unavailable
    case ambiguous
    case lookupLimit
    case rejected(AXError)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Safari's Paste command is unavailable for the original field."
        case .ambiguous:
            "Safari has more than one matching Paste command; nothing was pasted."
        case .lookupLimit:
            "Safari's menu could not be inspected within the safety limit."
        case .rejected(let error):
            "Safari rejected the Paste command (AX error \(error.rawValue))."
        }
    }
}

/// The standard Command-V command in one application's native menu bar.
@MainActor
struct AccessibilityPasteCommand {
    private let item: AXUIElement
    private let pid: pid_t
    private static let messagingTimeout: Float = 0.15

    static func find(for pid: pid_t) throws -> Self {
        var lookup = Lookup(pid: pid)
        let application = AXUIElementCreateApplication(pid)
        try lookup.prepare(application)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            application, kAXMenuBarAttribute as CFString, &value)
        guard status == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { throw AccessibilityPasteCommandError.unavailable }
        let menuBar = unsafeDowncast(value, to: AXUIElement.self)
        var match: AXUIElement?
        // Only native top-level commands. Do not walk bookmark submenus or
        // web content looking for something that happens to have this shortcut.
        for heading in try lookup.children(of: menuBar, role: kAXMenuBarRole, maximum: 64) {
            for menu in try lookup.children(of: heading, role: kAXMenuBarItemRole, maximum: 8) {
                for item in try lookup.children(of: menu, role: kAXMenuRole, maximum: 512) {
                    try lookup.prepare(item)
                    guard try attributes(of: item).matches else { continue }
                    if let match, !CFEqual(match, item) {
                        throw AccessibilityPasteCommandError.ambiguous
                    }
                    match = item
                }
            }
        }
        guard let match else { throw AccessibilityPasteCommandError.unavailable }
        return Self(item: match, pid: pid)
    }

    /// Called after the temporary text is on the clipboard, because the old
    /// clipboard contents may have kept Paste disabled during lookup.
    func validate() throws {
        try Self.prepare(item, pid: pid)
        let attributes = try Self.attributes(of: item)
        guard attributes.matches, attributes.enabled else {
            throw AccessibilityPasteCommandError.unavailable
        }
    }

    func perform() throws {
        // The action may wait for Safari's web process. A timeout is an
        // uncertain handoff, so callers must not retry with another mechanism.
        let timeout = AXUIElementSetMessagingTimeout(item, 2)
        guard timeout == .success else { throw AccessibilityPasteCommandError.rejected(timeout) }
        let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard status == .success else { throw AccessibilityPasteCommandError.rejected(status) }
    }

    static func matchesPasteShortcut(character: String?, modifiers: Int?) -> Bool {
        character?.lowercased() == "v" && modifiers == 0
    }

    private static func prepare(_ element: AXUIElement, pid: pid_t) throws {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else {
            throw AccessibilityPasteCommandError.unavailable
        }
        let status = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard status == .success else { throw AccessibilityPasteCommandError.rejected(status) }
    }

    private static func attributes(of element: AXUIElement) throws -> (matches: Bool, enabled: Bool)
    {
        let names =
            [
                kAXRoleAttribute, kAXMenuItemCmdCharAttribute,
                kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute,
            ] as CFArray
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
        guard status == .success else {
            throw AccessibilityPasteCommandError.rejected(status)
        }
        guard let values = values as? [Any], values.count == 4 else {
            throw AccessibilityPasteCommandError.unavailable
        }
        let matches =
            values[0] as? String == kAXMenuItemRole as String
            && matchesPasteShortcut(
                character: values[1] as? String, modifiers: (values[2] as? NSNumber)?.intValue)
        return (matches, values[3] as? Bool == true)
    }

    @MainActor
    private struct Lookup {
        let pid: pid_t
        private let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        private var remaining = 1024

        init(pid: pid_t) { self.pid = pid }

        func prepare(_ element: AXUIElement) throws {
            guard ContinuousClock.now < deadline else {
                throw AccessibilityPasteCommandError.lookupLimit
            }
            try AccessibilityPasteCommand.prepare(element, pid: pid)
        }

        mutating func children(of element: AXUIElement, role: String, maximum: Int) throws
            -> [AXUIElement]
        {
            try prepare(element)
            var roleValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
                    == .success, roleValue as? String == role
            else { throw AccessibilityPasteCommandError.unavailable }
            var count = 0
            try prepare(element)
            let status = AXUIElementGetAttributeValueCount(
                element, kAXChildrenAttribute as CFString, &count)
            guard status == .success else { throw AccessibilityPasteCommandError.rejected(status) }
            guard count >= 0, count <= maximum, count <= remaining else {
                throw AccessibilityPasteCommandError.lookupLimit
            }
            guard count != 0 else { return [] }
            remaining -= count
            try prepare(element)
            var values: CFArray?
            let copied = AXUIElementCopyAttributeValues(
                element, kAXChildrenAttribute as CFString, 0, count, &values)
            guard copied == .success, let children = values as? [AXUIElement],
                children.count == count
            else { throw AccessibilityPasteCommandError.unavailable }
            return children
        }
    }
}
