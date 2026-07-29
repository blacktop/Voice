import CryptoKit
import Foundation
import XCTest

@testable import VoicePlatform

final class EncryptedHistoryStoreTests: XCTestCase {
    func testPersistenceIsOptIn() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(isEnabled: false)

        do {
            try await store.append(.init(kind: .insertedPrompt, text: "private prompt"))
            XCTFail("Expected disabled history to reject persistence")
        } catch let error as EncryptedHistoryStoreError {
            XCTAssertEqual(error, .disabled)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storageURL.path))
    }

    func testRoundTripsEncryptedTextWithoutUsingKeychain() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }
        let firstStore = fixture.makeStore(isEnabled: true)
        let entry = LocalHistoryEntry(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_234),
            kind: .planningPrompt,
            text: "Explain the AgentTransport cancellation path"
        )

        try await firstStore.append(entry)

        let persistedData = try Data(contentsOf: fixture.storageURL)
        XCTAssertNil(persistedData.range(of: Data(entry.text.utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.storageURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let reopenedStore = fixture.makeStore(isEnabled: true)
        let reopenedEntries = try await reopenedStore.entries()
        XCTAssertEqual(reopenedEntries, [entry])
    }

    func testKeyProviderFailuresAreNotMisreportedAsCorruption() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(isEnabled: true)
        try await store.append(.init(kind: .insertedPrompt, text: "persisted text"))

        let unavailableStore = EncryptedHistoryStore(
            storageURL: fixture.storageURL,
            keyProvider: UnavailableHistoryKeyProvider(),
            isEnabled: true
        )
        do {
            _ = try await unavailableStore.entries()
            XCTFail("Expected the injected key provider failure")
        } catch let error as TestHistoryKeyError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testWrongKeyAndTamperingAreRejected() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(isEnabled: true)
        try await store.append(.init(kind: .planningResponse, text: "local response"))

        let wrongKeyStore = EncryptedHistoryStore(
            storageURL: fixture.storageURL,
            keyProvider: FixedHistoryKeyProvider(byte: 0x7B),
            isEnabled: true
        )
        do {
            _ = try await wrongKeyStore.entries()
            XCTFail("Expected a different key to fail authentication")
        } catch let error as EncryptedHistoryStoreError {
            XCTAssertEqual(error, .corruptedHistory)
        }

        var data = try Data(contentsOf: fixture.storageURL)
        let finalIndex = try XCTUnwrap(data.indices.last)
        data[finalIndex] ^= 0x01
        try data.write(to: fixture.storageURL, options: [.atomic])

        do {
            _ = try await store.entries()
            XCTFail("Expected ciphertext tampering to fail authentication")
        } catch let error as EncryptedHistoryStoreError {
            XCTAssertEqual(error, .corruptedHistory)
        }
    }

    func testBoundedHistoryDeletesOldestEntries() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(isEnabled: true, maximumEntries: 2)
        let entries = [
            LocalHistoryEntry(kind: .insertedPrompt, text: "one"),
            LocalHistoryEntry(kind: .insertedPrompt, text: "two"),
            LocalHistoryEntry(kind: .insertedPrompt, text: "three"),
        ]

        for entry in entries {
            try await store.append(entry)
        }

        let persistedEntries = try await store.entries()
        XCTAssertEqual(persistedEntries, Array(entries.suffix(2)))
    }

    func testClearWorksAfterHistoryIsDisabled() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(isEnabled: true)
        try await store.append(.init(kind: .insertedPrompt, text: "delete me"))
        await store.setEnabled(false)

        try await store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storageURL.path))
    }
}

private struct FixedHistoryKeyProvider: HistoryKeyProviding {
    let byte: UInt8

    func loadOrCreateKey() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: byte, count: 32))
    }
}

private enum TestHistoryKeyError: Error, Equatable {
    case unavailable
}

private struct UnavailableHistoryKeyProvider: HistoryKeyProviding {
    func loadOrCreateKey() throws -> SymmetricKey {
        throw TestHistoryKeyError.unavailable
    }
}

private struct TemporaryHistoryFixture {
    let directoryURL: URL
    let storageURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storageURL = directoryURL.appendingPathComponent("history.voicehistory")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func makeStore(
        isEnabled: Bool,
        maximumEntries: Int = 500
    ) -> EncryptedHistoryStore {
        EncryptedHistoryStore(
            storageURL: storageURL,
            keyProvider: FixedHistoryKeyProvider(byte: 0xA5),
            isEnabled: isEnabled,
            maximumEntries: maximumEntries
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
