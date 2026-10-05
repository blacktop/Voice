import AppKit
import Darwin
import Foundation
import Security
import Synchronization

/// Socket and tmux calls block in poll() for seconds at a time. Running them
/// on a GCD worker keeps a stalled peer from holding one of the few threads in
/// Swift concurrency's cooperative pool, which the app's speech work shares.
enum BlockingCall {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }
}

enum NotificationSocket {
    // Includes the worst-case JSON escaping of every validated text field.
    static let maximumFrame = 131_072
    static let directoryName = "io.blacktop.Voice.notify"

    static func path() throws -> String {
        // Agent processes may override TMPDIR. Resolve the per-user Darwin
        // directory so Launch Services and every CLI find the same endpoint.
        var temporary = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &temporary, temporary.count)
        guard count > 1, count <= temporary.count else {
            throw VoiceNotificationError("cannot resolve the user notification directory")
        }
        let temporaryPath = String(
            decoding: temporary.prefix(count - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let directory = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true).path
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw VoiceNotificationError("cannot create private notification directory")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0
        else { throw VoiceNotificationError("notification directory is not private") }
        return directory + "/rpc.sock"
    }

    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T)
        throws -> T
    {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw VoiceNotificationError("notification socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func make() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw VoiceNotificationError("cannot create notification socket")
        }
        do { try prepare(descriptor) } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    static func prepare(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                socklen_t(MemoryLayout.size(ofValue: enabled))) == 0
        else { throw VoiceNotificationError("cannot configure notification socket") }
    }

    static func wait(_ descriptor: Int32, events: Int16, until deadline: ContinuousClock.Instant)
        throws
    {
        while ContinuousClock.now < deadline {
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let status = poll(&item, 1, 100)
            if status > 0 {
                guard item.revents & (events | Int16(POLLHUP)) != 0 else {
                    throw VoiceNotificationError("notification socket disconnected")
                }
                return
            }
            if status < 0, errno != EINTR {
                throw VoiceNotificationError("notification socket poll failed")
            }
        }
        throw VoiceNotificationError("notification request timed out")
    }

    static func connect(_ path: String) throws -> Int32? {
        let descriptor = try make()
        let status: Int32
        do { status = try address(path) { Darwin.connect(descriptor, $0, $1) } } catch {
            close(descriptor)
            throw error
        }
        if status == 0 { return descriptor }
        let failure = errno
        if failure == EINPROGRESS {
            do {
                try wait(descriptor, events: Int16(POLLOUT), until: .now.advanced(by: .seconds(2)))
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout.size(ofValue: socketError))
                if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
                    socketError == 0
                {
                    return descriptor
                }
            } catch {
                close(descriptor)
                throw error
            }
        }
        close(descriptor)
        if failure == ENOENT || failure == ECONNREFUSED { return nil }
        throw VoiceNotificationError("cannot connect to Voice notification service")
    }

    static func read(_ descriptor: Int32, count: Int, until deadline: ContinuousClock.Instant)
        throws -> Data
    {
        guard (0...maximumFrame).contains(count) else {
            throw VoiceNotificationError("invalid notification frame length")
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                try wait(descriptor, events: Int16(POLLIN), until: deadline)
                let size = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if size > 0 {
                    offset += size
                } else if size == 0 {
                    throw VoiceNotificationError("notification socket closed before its reply")
                } else if errno != EINTR && errno != EAGAIN {
                    throw VoiceNotificationError("notification socket read failed")
                }
            }
        }
        return data
    }

    static func receive<T: Decodable>(
        _ type: T.Type, from descriptor: Int32, until deadline: ContinuousClock.Instant
    ) throws -> T {
        let header = try read(descriptor, count: 4, until: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumFrame else {
            throw VoiceNotificationError("invalid notification frame length")
        }
        do {
            return try JSONDecoder().decode(
                type, from: read(descriptor, count: count, until: deadline))
        } catch let error as VoiceNotificationError { throw error } catch {
            throw VoiceNotificationError("invalid notification response")
        }
    }

    static func send<T: Encodable>(
        _ value: T, to descriptor: Int32, until deadline: ContinuousClock.Instant
    ) throws {
        let body = try JSONEncoder().encode(value)
        guard !body.isEmpty, body.count <= maximumFrame else {
            throw VoiceNotificationError("notification request is too large")
        }
        var length = UInt32(body.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(body)
        try framed.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), until: deadline)
                let size = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if size > 0 {
                    offset += size
                } else if size == 0 || (errno != EINTR && errno != EAGAIN) {
                    throw VoiceNotificationError("notification socket write failed")
                }
            }
        }
    }

    static func sameUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
    }
}

/// An immutable requirement for a socket peer, resolved before serving or
/// connecting. No mutable Security object crosses the background exchange.
struct NotificationAppIdentity: @unchecked Sendable {
    let requirement: SecRequirement

    init(requirement: SecRequirement) { self.requirement = requirement }

    @concurrent
    static func load(appURL: URL) async throws -> Self { try Self(appURL: appURL) }

    init(appURL: URL) throws {
        let team = try Self.currentTeam()
        var app: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &app) == errSecSuccess,
            let app
        else { throw VoiceNotificationError("Voice or this CLI has no valid code signature") }
        guard
            try Self.info(app)[kSecCodeInfoIdentifier as String] as? String == "io.blacktop.Voice",
            SecStaticCodeCheckValidity(
                app, SecCSFlags(rawValue: kSecCSStrictValidate), team.requirement) == errSecSuccess
        else {
            throw VoiceNotificationError(
                "Voice and its CLI require Apple-issued signatures from the same developer")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(app, [], &requirement) == errSecSuccess,
            let requirement
        else {
            throw VoiceNotificationError("Voice has no designated signing requirement")
        }
        self.requirement = requirement
    }

    static func currentTeam() throws -> Self {
        var ownCode: SecCode?
        var ownStatic: SecStaticCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
            SecCodeCopyStaticCode(ownCode, [], &ownStatic) == errSecSuccess, let ownStatic
        else { throw VoiceNotificationError("this process has no valid code signature") }
        let teamRequirement = try requirement(forTeam: teamIdentifier(ownStatic))
        guard
            SecCodeCheckValidity(
                ownCode, SecCSFlags(rawValue: kSecCSStrictValidate), teamRequirement)
                == errSecSuccess
        else {
            throw VoiceNotificationError(
                "Voice and its CLI require Apple-issued signatures from the same developer")
        }
        return Self(requirement: teamRequirement)
    }

    private static func teamIdentifier(_ code: SecStaticCode) throws -> String {
        guard let team = try info(code)[kSecCodeInfoTeamIdentifier as String] as? String,
            team.utf8.count == 10,
            team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
        else { throw VoiceNotificationError("this process has no valid signing team") }
        return team
    }

    private static func requirement(forTeam team: String) throws -> SecRequirement {
        // A TeamIdentifier string alone is not a trust anchor: a locally
        // created certificate can carry the same subject OU. Require the
        // Apple-issued signing chain as well as the expected team.
        var teamRequirement: SecRequirement?
        let teamRule = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard
            SecRequirementCreateWithString(teamRule as CFString, [], &teamRequirement)
                == errSecSuccess,
            let teamRequirement
        else {
            throw VoiceNotificationError(
                "Voice and its CLI require Apple-issued signatures from the same developer")
        }
        return teamRequirement
    }

    private static func info(_ code: SecStaticCode) throws -> [String: Any] {
        var value: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess,
            let result = value as? [String: Any]
        else { throw VoiceNotificationError("could not read Voice signing identity") }
        return result
    }

    func verify(_ descriptor: Int32) throws {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue: token))
        guard NotificationSocket.sameUser(descriptor),
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
            size == MemoryLayout.size(ofValue: token)
        else { throw VoiceNotificationError("could not authenticate Voice socket peer") }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
            let guest,
            SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                == errSecSuccess
        else {
            throw VoiceNotificationError("notification socket peer has an untrusted code signature")
        }
    }
}

public enum NotificationClient {
    @MainActor
    public static func send(_ request: NotificationRPCRequest) async throws
        -> NotificationRPCResponse
    {
        let (request, pushFailure) = try prepare(request)
        var response = try await sendPrepared(request)
        if let pushFailure { response.failures.append(pushFailure) }
        return response
    }

    static func prepare(_ request: NotificationRPCRequest) throws
        -> (NotificationRPCRequest, String?)
    {
        switch request {
        case .post(var message), .postWithProject(var message):
            try message.validate()
            guard message.push else {
                message.pushOverrides = nil
                return (postRequest(message), nil)
            }
            do { try message.pushOverrides?.validate() } catch {
                // Invalid optional credentials must not prevent the Mac alert
                // or make the bounded RPC encode an arbitrarily large value.
                message.push = false
                message.pushOverrides = nil
                return (postRequest(message), "push: \(error.localizedDescription)")
            }
            return (postRequest(message), nil)
        case .configurePush(let configuration):
            try configuration.validate()
            return (request, nil)
        }
    }

    private static func postRequest(_ message: NotificationMessage) -> NotificationRPCRequest {
        message.zedProject == nil ? .post(message) : .postWithProject(message)
    }

    @MainActor
    private static func sendPrepared(_ request: NotificationRPCRequest) async throws
        -> NotificationRPCResponse
    {
        let appURL = try applicationURL(
            executableURL: Bundle.main.executableURL,
            installedAppURL: URL(fileURLWithPath: "/Applications/Voice.app"),
            registeredAppURL: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.blacktop.Voice")
            })
        let identity = try await NotificationAppIdentity.load(appURL: appURL)
        let path = try NotificationSocket.path()
        if let descriptor = try await connect(path) {
            return try await exchange(request, descriptor: descriptor, identity: identity)
        }
        try await launch(appURL)
        let descriptor = try await waitForService(path: path, appURL: appURL)
        return try await exchange(request, descriptor: descriptor, identity: identity)
    }

    @MainActor
    static func applicationURL(
        executableURL: URL?, installedAppURL: URL, registeredAppURL: () -> URL?
    ) throws -> URL {
        let containingApp = executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for candidate in [containingApp, installedAppURL].compactMap({ $0 }) {
            if Bundle(url: candidate)?.bundleIdentifier == "io.blacktop.Voice" {
                return candidate
            }
        }
        guard let registered = registeredAppURL() else {
            throw VoiceNotificationError("Voice is not installed; run just install-app")
        }
        return registered
    }

    @MainActor
    private static func launch(_ appURL: URL) async throws {
        try checkLaunch(
            appURL: appURL,
            runningAppURLs: NSRunningApplication.runningApplications(
                withBundleIdentifier: "io.blacktop.Voice"
            ).filter { !$0.isTerminated }.map(\.bundleURL))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // The selected, verified build may differ from an older running copy.
        configuration.allowsRunningApplicationSubstitution = false
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let result = NotificationLaunchResult(continuation)
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) {
                application, error in
                if let error {
                    let failure = error as NSError
                    result.finish(
                        .failure(
                            VoiceNotificationError(
                                "could not launch Voice: \(failure.localizedDescription) "
                                    + "(\(failure.domain) \(failure.code))")))
                } else if application != nil {
                    result.finish(.success(()))
                } else {
                    result.finish(.failure(VoiceNotificationError("could not launch Voice")))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                result.finish(
                    .failure(VoiceNotificationError("could not launch Voice within 10 seconds")))
            }
        }
    }

    private static func waitForService(path: String, appURL: URL) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let descriptor = try await connect(path) {
                return descriptor
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw VoiceNotificationError(
            "Voice notification service did not start at \(appURL.path); "
                + "quit and reopen that app, then retry")
    }

    static func checkLaunch(
        appURL: URL, runningAppURLs: [URL?], applicationName: String = "Voice"
    ) throws {
        let selected = appURL.resolvingSymlinksInPath().standardizedFileURL
        for running in runningAppURLs {
            guard let running else {
                throw VoiceNotificationError("quit the running \(applicationName) app, then retry")
            }
            let runningURL = running.resolvingSymlinksInPath().standardizedFileURL
            guard runningURL == selected else {
                throw VoiceNotificationError(
                    "quit the \(applicationName) running at \(runningURL.path), then retry")
            }
        }
    }

    private static func connect(_ path: String) async throws -> Int32? {
        try await BlockingCall.run { try NotificationSocket.connect(path) }
    }

    private static func exchange(
        _ request: NotificationRPCRequest, descriptor: Int32, identity: NotificationAppIdentity
    ) async throws -> NotificationRPCResponse {
        try await BlockingCall.run {
            defer { close(descriptor) }
            return try exchange(request, descriptor: descriptor) {
                try identity.verify(descriptor)
            }
        }
    }

    static func exchange(
        _ request: NotificationRPCRequest, descriptor: Int32, authenticate: () throws -> Void
    ) throws -> NotificationRPCResponse {
        // The injectable authentication boundary lets tests prove that no
        // request bytes (including credentials) leave on a rejected peer.
        try authenticate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(70))
        try NotificationSocket.send(request, to: descriptor, until: deadline)
        return try NotificationSocket.receive(
            NotificationRPCResponse.self, from: descriptor, until: deadline)
    }
}

private final class NotificationLaunchResult: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, any Error>?>

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func finish(_ result: Result<Void, VoiceNotificationError>) {
        let pending = continuation.withLock { value in
            let pending = value
            value = nil
            return pending
        }
        pending?.resume(with: result.mapError { $0 as any Error })
    }
}

final class NotificationServer {
    private let source: any DispatchSourceRead

    init(
        path requestedPath: String? = nil,
        clientIdentity: NotificationAppIdentity? = nil,
        handler: @escaping @Sendable (NotificationRPCRequest) async -> NotificationRPCResponse
    )
        throws
    {
        let clientIdentity = try clientIdentity ?? NotificationAppIdentity.currentTeam()
        let path = try requestedPath ?? NotificationSocket.path()
        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            throw VoiceNotificationError("cannot open notification service lock")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw VoiceNotificationError("another Voice notification service is running")
        }
        var descriptor: Int32 = -1
        do {
            descriptor = try NotificationSocket.make()
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                    throw VoiceNotificationError("invalid existing notification socket")
                }
                if let live = try NotificationSocket.connect(path) {
                    close(live)
                    throw VoiceNotificationError("notification socket is already active")
                }
                guard unlink(path) == 0 else {
                    throw VoiceNotificationError("cannot remove stale notification socket")
                }
            }
            guard try NotificationSocket.address(path, { bind(descriptor, $0, $1) }) == 0,
                chmod(path, 0o600) == 0, listen(descriptor, 8) == 0
            else { throw VoiceNotificationError("cannot listen for Voice notifications") }
        } catch {
            if descriptor >= 0 { close(descriptor) }
            close(lock)
            throw error
        }
        let listener = descriptor
        let capacity = DispatchSemaphore(value: 8)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: listener,
            queue: DispatchQueue(label: "io.blacktop.Voice.notifications.accept"))
        source.setEventHandler {
            for _ in 0..<16 {
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { return }
                guard NotificationSocket.sameUser(peer), capacity.wait(timeout: .now()) == .success
                else {
                    close(peer)
                    continue
                }
                Task.detached {
                    defer {
                        close(peer)
                        capacity.signal()
                    }
                    do {
                        let request = try await BlockingCall.run {
                            try clientIdentity.verify(peer)
                            try NotificationSocket.prepare(peer)
                            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                            return try NotificationSocket.receive(
                                NotificationRPCRequest.self, from: peer, until: deadline)
                        }
                        let response = await handler(request)
                        try await BlockingCall.run {
                            try NotificationSocket.send(
                                response, to: peer, until: .now.advanced(by: .seconds(5)))
                        }
                    } catch {
                        // Peer disconnects and malformed frames are isolated to
                        // this bounded connection. Never log request contents.
                    }
                }
            }
        }
        source.setCancelHandler {
            close(listener)
            unlink(path)
            close(lock)
        }
        self.source = source
        source.resume()
    }

    deinit { source.cancel() }
}
