import AppKit
import Foundation
import os

enum ClipboardInsertionError: LocalizedError {
    case unavailable
    case tooLarge
    case changed
    case busy

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Voice could not preserve the clipboard. Check Voice's Paste from Other Apps permission in System Settings."
        case .tooLarge:
            "The text or clipboard is too large to preserve safely. Copy a smaller item and try again."
        case .changed:
            "The clipboard changed before insertion; nothing was pasted."
        case .busy:
            "Another clipboard insertion is still finishing."
        }
    }
}

/// Temporarily lends the local pasteboard to a verified, process-targeted paste.
@MainActor
final class ClipboardTextInsertion {
    static let maximumTextBytes = 8 * 1024 * 1024
    static let maximumSnapshotBytes = 64 * 1024 * 1024
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static let logger = Logger(subsystem: "io.blacktop.Voice", category: "insertion")
    private var isPasting = false

    func perform(
        _ text: String,
        on pasteboard: NSPasteboard = .general,
        maximumSnapshotBytes: Int = maximumSnapshotBytes,
        verifyTarget: () throws -> Void,
        validatePaste: () throws -> Void = {},
        paste: () throws -> Void,
        settle: () async -> Void = {
            // Give the target time to consume the paste even if Voice's turn
            // is cancelled after posting it. This task is always awaited.
            await Task { try? await Task.sleep(for: .milliseconds(250)) }.value
        }
    ) async throws {
        guard !isPasting else { throw ClipboardInsertionError.busy }
        guard text.utf8.count <= Self.maximumTextBytes else {
            throw ClipboardInsertionError.tooLarge
        }
        try Task.checkCancellation()
        let text = Self.safeText(text)
        guard !text.isEmpty else { return }
        isPasting = true
        defer { isPasting = false }

        try verifyTarget()
        let snapshot = try PasteboardSnapshot(pasteboard, maximumBytes: maximumSnapshotBytes)
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
            item.setData(Data(), forType: Self.transientType),
            item.setData(Data(), forType: Self.concealedType)
        else { throw ClipboardInsertionError.unavailable }
        guard pasteboard.changeCount == snapshot.changeCount else {
            throw ClipboardInsertionError.changed
        }
        let ownership = pasteboard.prepareForNewContents(with: .currentHostOnly)
        defer {
            if !snapshot.restore(to: pasteboard, ifOwnedSince: ownership) {
                Self.logger.notice("clipboard changed or could not be restored after insertion")
            }
        }
        guard pasteboard.writeObjects([item]) else { throw ClipboardInsertionError.unavailable }
        try Task.checkCancellation()
        try verifyTarget()
        try validatePaste()
        guard pasteboard.changeCount == ownership else { throw ClipboardInsertionError.changed }
        let result = Result { try paste() }
        await settle()
        try result.get()
    }

    static func safeText(_ text: String) -> String {
        // No pasted Return, escape sequence, or other terminal control input.
        // Preserve formatting scalars such as emoji joiners and variation selectors.
        let text = UnicodeEventPayloadPlan.sanitizedText(text)
        return String(
            text.unicodeScalars.filter {
                $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
            })
    }
}

@MainActor
private struct PasteboardSnapshot {
    let changeCount: Int
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard, maximumBytes: Int) throws {
        changeCount = pasteboard.changeCount
        let originals = pasteboard.pasteboardItems ?? []
        guard originals.count <= 64, maximumBytes >= 0 else {
            throw ClipboardInsertionError.tooLarge
        }
        var remainingBytes = maximumBytes
        var remainingTypes = 256
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in originals {
            guard item.types.count <= remainingTypes else { throw ClipboardInsertionError.tooLarge }
            remainingTypes -= item.types.count
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw ClipboardInsertionError.unavailable
                }
                guard data.count <= remainingBytes else { throw ClipboardInsertionError.tooLarge }
                remainingBytes -= data.count
                values.append((type, data))
            }
            items.append(values)
        }
        guard pasteboard.changeCount == changeCount else { throw ClipboardInsertionError.changed }
        self.items = items
    }

    func restore(to pasteboard: NSPasteboard, ifOwnedSince ownership: Int) -> Bool {
        guard pasteboard.changeCount == ownership else { return false }
        let restored = items.map { item in
            let value = NSPasteboardItem()
            for (type, data) in item { value.setData(data, forType: type) }
            return value
        }
        guard pasteboard.changeCount == ownership else { return false }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}
