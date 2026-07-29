import CryptoKit
import Foundation
import Security

/// Supplies the encryption key used by local history persistence.
public protocol HistoryKeyProviding: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

public enum HistoryKeyProviderError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidKeyData

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Keychain operation failed with status \(status)."
        case .invalidKeyData:
            "The history encryption key stored in Keychain is invalid."
        }
    }
}

/// Stores a device-bound 256-bit history key in the user's Keychain.
public struct KeychainHistoryKeyProvider: HistoryKeyProviding {
    private let service: String
    private let account: String

    public init(
        service: String = "io.blacktop.Voice.encrypted-history",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        switch try existingKey() {
        case .some(let key):
            return key
        case .none:
            break
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            // Without the data-protection keychain, macOS stores the item in
            // the legacy login keychain, which ignores the accessibility class
            // and lets the key migrate off-device.
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: keyData,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem, let concurrentlyCreatedKey = try existingKey() {
            return concurrentlyCreatedKey
        }
        guard status == errSecSuccess else {
            throw HistoryKeyProviderError.keychain(status)
        }
        return key
    }

    private func existingKey() throws -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw HistoryKeyProviderError.keychain(status)
        }
        guard let keyData = result as? Data, keyData.count == 32 else {
            throw HistoryKeyProviderError.invalidKeyData
        }
        return SymmetricKey(data: keyData)
    }
}

/// A text-only item eligible for encrypted local history.
///
/// Raw audio is intentionally absent from this model and is never accepted by the store.
public struct LocalHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case insertedPrompt
        case planningPrompt
        case planningResponse
    }

    public let id: UUID
    public let createdAt: Date
    public let kind: Kind
    public let text: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: Kind,
        text: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
    }
}

public enum EncryptedHistoryStoreError: LocalizedError, Equatable, Sendable {
    case disabled
    case invalidStorageURL
    case emptyText
    case corruptedHistory
    case unsupportedVersion(UInt8)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Encrypted history is disabled."
        case .invalidStorageURL:
            "Encrypted history requires a local file URL."
        case .emptyText:
            "Empty text cannot be added to history."
        case .corruptedHistory:
            "Encrypted history is damaged or was encrypted with a different key."
        case .unsupportedVersion(let version):
            "Encrypted history version \(version) is not supported."
        }
    }
}

/// An opt-in, AES-GCM encrypted store for text-only local history.
public actor EncryptedHistoryStore {
    private static let magic: [UInt8] = [0x56, 0x4F, 0x49, 0x43, 0x45, 0x48, 0x53, 0x54]
    private static let formatVersion: UInt8 = 1

    private let storageURL: URL
    private let keyProvider: any HistoryKeyProviding
    private let maximumEntries: Int
    private var enabled: Bool

    public init(
        storageURL: URL,
        keyProvider: any HistoryKeyProviding = KeychainHistoryKeyProvider(),
        isEnabled: Bool = false,
        maximumEntries: Int = 500
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.keyProvider = keyProvider
        self.enabled = isEnabled
        self.maximumEntries = max(maximumEntries, 1)
    }

    public var isEnabled: Bool {
        enabled
    }

    /// Changes whether reads and writes are allowed. Disabling does not silently delete data.
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    /// Returns the oldest-to-newest history entries when persistence is enabled.
    public func entries() throws -> [LocalHistoryEntry] {
        try requireEnabled()
        return try readEntries()
    }

    /// Encrypts and appends a text-only history entry.
    public func append(_ entry: LocalHistoryEntry) throws {
        try requireEnabled()
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EncryptedHistoryStoreError.emptyText
        }

        var entries = try readEntries()
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        try writeEntries(entries)
    }

    public func delete(id: LocalHistoryEntry.ID) throws {
        try requireEnabled()
        var entries = try readEntries()
        entries.removeAll { $0.id == id }
        try writeEntries(entries)
    }

    /// Removes persisted history even when history has subsequently been disabled.
    public func clear() throws {
        try validateStorageURL()
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return
        }
        try fileManager.removeItem(at: storageURL)
    }

    private func requireEnabled() throws {
        guard enabled else {
            throw EncryptedHistoryStoreError.disabled
        }
        try validateStorageURL()
    }

    private func validateStorageURL() throws {
        guard storageURL.isFileURL else {
            throw EncryptedHistoryStoreError.invalidStorageURL
        }
    }

    private func readEntries() throws -> [LocalHistoryEntry] {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }

        let encryptedData = try Data(contentsOf: storageURL, options: [.mappedIfSafe])
        let headerLength = Self.magic.count + 1
        guard encryptedData.count > headerLength,
            Array(encryptedData.prefix(Self.magic.count)) == Self.magic
        else {
            throw EncryptedHistoryStoreError.corruptedHistory
        }

        let version = encryptedData[Self.magic.count]
        guard version == Self.formatVersion else {
            throw EncryptedHistoryStoreError.unsupportedVersion(version)
        }

        let key = try keyProvider.loadOrCreateKey()
        do {
            let combined = Data(encryptedData.dropFirst(headerLength))
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return try JSONDecoder().decode([LocalHistoryEntry].self, from: plaintext)
        } catch {
            throw EncryptedHistoryStoreError.corruptedHistory
        }
    }

    private func writeEntries(_ entries: [LocalHistoryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(entries)
        let key = try keyProvider.loadOrCreateKey()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw EncryptedHistoryStoreError.corruptedHistory
        }

        var encryptedData = Data(Self.magic)
        encryptedData.append(Self.formatVersion)
        encryptedData.append(combined)

        let fileManager = FileManager()
        let directoryURL = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encryptedData.write(to: storageURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
    }
}
