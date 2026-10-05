import Foundation
import LocalAuthentication
import Security

public struct NtfyOverrides: Codable, Sendable, Equatable {
    public var server: String?
    public var topic: String?
    public var token: String?

    public init(server: String? = nil, topic: String? = nil, token: String? = nil) {
        self.server = server
        self.topic = topic
        self.token = token
    }

    func validate() throws {
        if let server { _ = try NtfyConfiguration.serverURL(server) }
        if let topic { try NtfyConfiguration.validateTopic(topic) }
        if let token { try NtfyConfiguration.validateToken(token) }
    }

    public func resolve(stored: NtfyConfiguration?) throws -> NtfyConfiguration {
        try validate()
        guard let server = server ?? stored?.server, let topic = topic ?? stored?.topic else {
            throw VoiceNotificationError("run voice-notify configure-push first")
        }
        // A destination override must never forward a saved secret to a new
        // server. Supplying a token explicitly authorizes that destination.
        if token == nil, let saved = stored,
            try NtfyConfiguration.serverURL(server) != NtfyConfiguration.serverURL(saved.server)
        {
            throw VoiceNotificationError("a different ntfy server requires an explicit token")
        }
        guard let token = token ?? stored?.token else {
            throw VoiceNotificationError("ntfy token is missing")
        }
        let result = NtfyConfiguration(server: server, topic: topic, token: token)
        try result.validate()
        return result
    }
}

public struct NtfyConfiguration: Codable, Sendable, Equatable {
    public var server: String
    public var topic: String
    public var token: String

    public init(server: String, topic: String, token: String) {
        self.server = server
        self.topic = topic
        self.token = token
    }

    public func validate() throws {
        _ = try Self.serverURL(server)
        try Self.validateTopic(topic)
        try Self.validateToken(token)
    }

    static func serverURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 2048,
            let parts = URLComponents(string: value), parts.scheme == "https",
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            let url = parts.url
        else {
            throw VoiceNotificationError(
                "ntfy server must be an HTTPS URL without credentials, query, or fragment")
        }
        return url
    }

    static func validateTopic(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 64,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            })
        else {
            throw VoiceNotificationError(
                "ntfy topic must contain 1–64 letters, digits, hyphens, or underscores")
        }
    }

    static func validateToken(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096,
            value.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw VoiceNotificationError("ntfy token is empty or invalid") }
    }
}

struct NtfyPayload: Encodable {
    var topic: String
    var title: String
    var message: String
}

public enum NtfyPush {
    public static func request(for message: NotificationMessage, configuration: NtfyConfiguration)
        throws -> URLRequest
    {
        try configuration.validate()
        try message.validate()
        let body = [message.subtitle, message.message].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard body.utf8.count <= 4096 else {
            throw VoiceNotificationError("ntfy message and subtitle exceed 4096 UTF-8 bytes")
        }
        var request = URLRequest(url: try NtfyConfiguration.serverURL(configuration.server))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            NtfyPayload(topic: configuration.topic, title: message.title, message: body))
        return request
    }

    public static func checkStatus(_ status: Int) throws {
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 {
                throw VoiceNotificationError("ntfy rejected the credentials or topic access")
            }
            throw VoiceNotificationError("ntfy returned HTTP \(status)")
        }
    }

    public static func send(_ message: NotificationMessage, configuration: NtfyConfiguration)
        async throws
    {
        let request = try request(for: message, configuration: configuration)
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 20
        settings.httpMaximumConnectionsPerHost = 1
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        let session = URLSession(
            configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            // Inspect headers without accumulating an untrusted response body.
            let (_, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw VoiceNotificationError("ntfy returned an invalid response")
            }
            try checkStatus(response.statusCode)
        } catch let error as VoiceNotificationError { throw error } catch {
            throw VoiceNotificationError("ntfy HTTPS request failed")
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

/// One item keeps the destination and its credential atomic. Only the signed
/// Voice application calls this store; CLI tools send configuration over RPC.
struct NtfyKeychain {
    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.blacktop.Voice.notifications.ntfy",
            kSecAttrAccount as String: "configuration",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    func load() throws -> NtfyConfiguration? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try Self.checkStatus(status, operation: "read")
        guard let data = item as? Data, data.count <= 16_384,
            let configuration = try? JSONDecoder().decode(NtfyConfiguration.self, from: data)
        else { throw VoiceNotificationError("ntfy Keychain configuration is unavailable") }
        try configuration.validate()
        return configuration
    }

    func save(_ configuration: NtfyConfiguration) throws {
        try configuration.validate()
        let values: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(configuration),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil)
        }
        try Self.checkStatus(status, operation: "save")
    }

    static func checkStatus(_ status: OSStatus, operation: String) throws {
        if status == errSecMissingEntitlement {
            throw VoiceNotificationError(
                "Voice is missing its Keychain entitlement or provisioning profile; "
                    + "rebuild and reinstall a provisioned Voice app")
        }
        guard status == errSecSuccess else {
            throw VoiceNotificationError(
                "could not \(operation) ntfy configuration in Keychain (\(status))")
        }
    }
}
