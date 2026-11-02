import Foundation
import Synchronization

/// Feeds one bounded utterance at a time to any notification replay engine.
public enum NotificationSpeechReplay {
    @concurrent
    public static func speak(
        _ text: String, onStarted: @escaping @Sendable () -> Void,
        using speak: @Sendable (String, @escaping @Sendable () -> Void) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        var chunks = try NotificationSpeechChunks(text)
        let playback = PlaybackStart(onStarted)
        while let chunk = chunks.next() {
            try Task.checkCancellation()
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try await speak(chunk) { playback.report() }
        }
        try Task.checkCancellation()
    }

    private final class PlaybackStart: Sendable {
        private let reported = Mutex(false)
        private let action: @Sendable () -> Void

        init(_ action: @escaping @Sendable () -> Void) { self.action = action }

        func report() {
            let first = reported.withLock { reported in
                guard !reported else { return false }
                reported = true
                return true
            }
            if first { action() }
        }
    }
}

struct NotificationSpeechChunks: IteratorProtocol {
    static let maximumBytes = 1024
    private let bytes: [UInt8]
    private var start = 0

    init(_ text: String) throws {
        let data = Data(text.utf8)
        _ = try NotificationDetails.text(from: data)
        bytes = Array(data)
    }

    mutating func next() -> String? {
        guard start < bytes.count else { return nil }
        let begin = start
        var end = begin + min(Self.maximumBytes, bytes.count - begin)
        if end < bytes.count { end = boundary(upTo: end) }
        start = end
        return String(decoding: bytes[begin..<end], as: UTF8.self)
    }

    private func boundary(upTo limit: Int) -> Int {
        var end = limit
        while bytes[end] & 0xC0 == 0x80 { end -= 1 }
        let range = start..<end
        if let newline = bytes[range].lastIndex(of: 10) { return newline + 1 }
        if let sentence = range.last(where: { index in
            [33, 46, 63].contains(bytes[index]) && [9, 10, 13, 32].contains(bytes[index + 1])
        }) {
            return sentence + 1
        }
        if let space = bytes[range].lastIndex(where: { [9, 13, 32].contains($0) }) {
            return space + 1
        }
        return end
    }
}
