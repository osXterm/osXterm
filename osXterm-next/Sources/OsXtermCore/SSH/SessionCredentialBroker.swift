import Darwin
import Dispatch
import Foundation
import Security

/// The two helper executables use this small JSON-over-Unix-socket protocol.
/// The socket directory is mode 0700, the socket is mode 0600, and every
/// request must carry the random token for the active SSH session.
public enum CredentialBrokerPurpose: String, Codable, Sendable {
    case askPass
    case proxy
}

public struct CredentialBrokerRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let token: String
    public let purpose: CredentialBrokerPurpose
    public let prompt: String

    public init(
        version: Int = CredentialBrokerRequest.currentVersion,
        token: String,
        purpose: CredentialBrokerPurpose,
        prompt: String
    ) {
        self.version = version
        self.token = token
        self.purpose = purpose
        self.prompt = prompt
    }
}

public struct CredentialBrokerResponse: Codable, Equatable, Sendable {
    public let value: String?

    public init(value: String?) {
        self.value = value
    }
}

public enum CredentialBrokerError: Error, Equatable, Sendable {
    case emptyCredentialSet
    case invalidSocketPath
    case invalidToken
    case invalidRequest
    case unsupportedVersion(Int)
    case socketCreationFailed(Int32)
    case socketBindFailed(Int32)
    case socketPermissionFailed(Int32)
    case socketListenFailed(Int32)
    case socketConfigurationFailed(Int32)
    case socketConnectFailed(Int32)
    case socketReadFailed(Int32)
    case socketWriteFailed(Int32)
    case responseTooLarge
    case requestTooLarge
    case credentialUnavailable
}

extension CredentialBrokerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyCredentialSet:
            "At least one in-memory credential is required."
        case .invalidSocketPath:
            "The credential broker socket path is invalid."
        case .invalidToken:
            "The credential broker token is invalid."
        case .invalidRequest:
            "The credential broker request is invalid."
        case let .unsupportedVersion(version):
            "Credential broker protocol version \(version) is unsupported."
        case let .socketCreationFailed(status):
            "Could not create credential broker socket (errno \(status))."
        case let .socketBindFailed(status):
            "Could not bind credential broker socket (errno \(status))."
        case let .socketPermissionFailed(status):
            "Could not secure credential broker socket permissions (errno \(status))."
        case let .socketListenFailed(status):
            "Could not listen on credential broker socket (errno \(status))."
        case let .socketConfigurationFailed(status):
            "Could not configure credential broker socket (errno \(status))."
        case let .socketConnectFailed(status):
            "Could not connect to credential broker socket (errno \(status))."
        case let .socketReadFailed(status):
            "Could not read credential broker data (errno \(status))."
        case let .socketWriteFailed(status):
            "Could not write credential broker data (errno \(status))."
        case .responseTooLarge:
            "Credential broker response exceeds the allowed size."
        case .requestTooLarge:
            "Credential broker request exceeds the allowed size."
        case .credentialUnavailable:
            "No credential matches the helper request."
        }
    }
}

/// Keeps session secrets in memory and makes them available only to packaged
/// helpers for the lifetime of this broker. The values are never placed in an
/// OpenSSH argument, environment variable, or temporary file.
public final class SessionCredentialBroker: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (CredentialBrokerRequest) -> String?

    public let socketPath: String
    public let token: String

    private let directoryURL: URL
    private let listenerFileDescriptor: Int32
    private let listener: DispatchSourceRead
    private let acceptQueue = DispatchQueue(label: "com.osxterm.credential-broker.accept")
    private let workerQueue = DispatchQueue(
        label: "com.osxterm.credential-broker.worker",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lifecycleLock = NSLock()
    private let credentialLock = NSLock()
    private var credentials: [String: Data]
    private let requestHandler: RequestHandler?
    private var stopped = false

    /// `responses` is indexed by a lowercased prompt marker. A `default` key
    /// is used when no more specific marker matches.
    public init(
        responses: [String: String],
        requestHandler: RequestHandler? = nil,
        baseDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    ) throws {
        let normalized = responses.reduce(into: [String: Data]()) { result, pair in
            let marker = pair.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !marker.isEmpty, !pair.value.isEmpty else { return }
            result[marker] = Data(pair.value.utf8)
        }
        guard !normalized.isEmpty || requestHandler != nil else {
            throw CredentialBrokerError.emptyCredentialSet
        }

        let suffix = UUID().uuidString.lowercased().prefix(16)
        let preferredDirectory = baseDirectory.appendingPathComponent(
            "osxterm-session-\(suffix)",
            isDirectory: true
        )
        // Unix-domain socket paths have a small platform limit. Falling back
        // to /private/tmp still preserves mode 0700 isolation and prevents a
        // long Application Support path from making password auth impossible.
        let directoryURL: URL
        if Self.isSafeSocketPath(preferredDirectory.appendingPathComponent("credentials.sock").path) {
            directoryURL = preferredDirectory
        } else {
            directoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("osxterm-session-\(suffix)", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let socketPath = directoryURL.appendingPathComponent("credentials.sock").path
        guard Self.isSafeSocketPath(socketPath) else {
            try? FileManager.default.removeItem(at: directoryURL)
            throw CredentialBrokerError.invalidSocketPath
        }

        let token = try Self.makeToken()
        let listenerFileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFileDescriptor >= 0 else {
            let status = errno
            try? FileManager.default.removeItem(at: directoryURL)
            throw CredentialBrokerError.socketCreationFailed(status)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(listenerFileDescriptor)
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        var address = try Self.socketAddress(path: socketPath)
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listenerFileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard didBind == 0 else {
            throw CredentialBrokerError.socketBindFailed(errno)
        }
        guard Darwin.chmod(socketPath, mode_t(0o600)) == 0 else {
            throw CredentialBrokerError.socketPermissionFailed(errno)
        }
        guard Darwin.listen(listenerFileDescriptor, SOMAXCONN) == 0 else {
            throw CredentialBrokerError.socketListenFailed(errno)
        }

        let flags = Darwin.fcntl(listenerFileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(listenerFileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }

        let listener = DispatchSource.makeReadSource(
            fileDescriptor: listenerFileDescriptor,
            queue: acceptQueue
        )
        self.socketPath = socketPath
        self.token = token
        self.directoryURL = directoryURL
        self.listenerFileDescriptor = listenerFileDescriptor
        self.listener = listener
        self.credentials = normalized
        self.requestHandler = requestHandler

        listener.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        listener.setCancelHandler {
            Darwin.close(listenerFileDescriptor)
        }
        listener.resume()
        shouldClose = false
    }

    deinit {
        stop()
    }

    public func stop() {
        lifecycleLock.lock()
        guard !stopped else {
            lifecycleLock.unlock()
            return
        }
        stopped = true
        lifecycleLock.unlock()

        clearCredentials()
        listener.cancel()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func acceptConnections() {
        while true {
            let client = Darwin.accept(listenerFileDescriptor, nil, nil)
            guard client >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }
            // The listening socket is nonblocking so this loop can drain it.
            // Accepted sockets may inherit that flag, but a framed request is
            // written in more than one syscall. Handle each client on a
            // blocking worker socket so a partial request cannot be mistaken
            // for an unavailable credential.
            guard Self.prepareConnectedSocket(client) else {
                Darwin.close(client)
                continue
            }
            workerQueue.async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer {
            _ = Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }

        do {
            let data = try Self.readFrame(from: client, maximumLength: 64 * 1024)
            let request = try JSONDecoder().decode(CredentialBrokerRequest.self, from: data)
            guard request.version == CredentialBrokerRequest.currentVersion else {
                throw CredentialBrokerError.unsupportedVersion(request.version)
            }
            guard Self.secureCompare(request.token, token) else {
                throw CredentialBrokerError.invalidToken
            }
            let value = credential(for: request.prompt) ?? requestHandler?(request)
            let response = try JSONEncoder().encode(CredentialBrokerResponse(value: value))
            try Self.writeFrame(response, to: client)
        } catch {
            let response = CredentialBrokerResponse(value: nil)
            if let data = try? JSONEncoder().encode(response) {
                try? Self.writeFrame(data, to: client)
            }
        }
    }

    private func credential(for prompt: String) -> String? {
        credentialLock.lock()
        defer { credentialLock.unlock() }

        let normalizedPrompt = prompt.lowercased()
        let best = credentials.keys
            .filter { $0 != "default" && normalizedPrompt.contains($0) }
            .sorted { $0.count > $1.count }
            .first
        let selected = best.flatMap { credentials[$0] } ?? credentials["default"]
        guard let selected else { return nil }
        return String(decoding: selected, as: UTF8.self)
    }

    private func clearCredentials() {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        for key in credentials.keys {
            guard var credential = credentials[key] else { continue }
            credential.resetBytes(in: 0 ..< credential.count)
            credentials[key] = credential
        }
        credentials.removeAll()
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CredentialBrokerError.invalidToken
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate static func prepareConnectedSocket(_ fileDescriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            return false
        }
        if flags & O_NONBLOCK != 0,
           Darwin.fcntl(fileDescriptor, F_SETFL, flags & ~O_NONBLOCK) != 0 {
            return false
        }

        var enabled: Int32 = 1
        return withUnsafePointer(to: &enabled) { pointer in
            Darwin.setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        }
    }

    static func isSafeSocketPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.contains("\0")
            && !path.unicodeScalars.contains(where: {
                CharacterSet.newlines.union(.controlCharacters).contains($0)
            })
            && path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    static func socketAddress(path: String) throws -> sockaddr_un {
        guard isSafeSocketPath(path) else {
            throw CredentialBrokerError.invalidSocketPath
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    fileprivate static func readFrame(
        from fileDescriptor: Int32,
        maximumLength: Int
    ) throws -> Data {
        var length = UInt32.zero
        try withUnsafeMutableBytes(of: &length) { buffer in
            try readExactly(into: buffer, from: fileDescriptor)
        }
        let expectedLength = Int(UInt32(bigEndian: length))
        guard expectedLength <= maximumLength else {
            throw CredentialBrokerError.requestTooLarge
        }
        var result = Data(count: expectedLength)
        try result.withUnsafeMutableBytes { buffer in
            try readExactly(into: buffer, from: fileDescriptor)
        }
        return result
    }

    fileprivate static func writeFrame(_ data: Data, to fileDescriptor: Int32) throws {
        guard data.count <= Int(UInt32.max) else {
            throw CredentialBrokerError.responseTooLarge
        }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { buffer in
            try writeExactly(buffer, to: fileDescriptor)
        }
        try data.withUnsafeBytes { buffer in
            try writeExactly(buffer, to: fileDescriptor)
        }
    }

    private static func readExactly(
        into buffer: UnsafeMutableRawBufferPointer,
        from fileDescriptor: Int32
    ) throws {
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.read(fileDescriptor, pointer, remaining)
            if count > 0 {
                remaining -= Int(count)
                pointer = pointer.advanced(by: Int(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw CredentialBrokerError.socketReadFailed(errno)
            }
        }
    }

    private static func writeExactly(
        _ buffer: UnsafeRawBufferPointer,
        to fileDescriptor: Int32
    ) throws {
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.write(fileDescriptor, pointer, remaining)
            if count > 0 {
                remaining -= Int(count)
                pointer = pointer.advanced(by: Int(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw CredentialBrokerError.socketWriteFailed(errno)
            }
        }
    }

    private static func secureCompare(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        var difference = UInt8(leftBytes.count ^ rightBytes.count)
        let count = max(leftBytes.count, rightBytes.count)
        for index in 0 ..< count {
            let lhs = index < leftBytes.count ? leftBytes[index] : 0
            let rhs = index < rightBytes.count ? rightBytes[index] : 0
            difference |= lhs ^ rhs
        }
        return difference == 0
    }
}

public enum AskPassClient {
    /// Requests a response for one OpenSSH AskPass prompt. The caller prints
    /// the returned text to stdout and must not log it.
    public static func requestResponse(
        socketPath: String,
        token: String,
        prompt: String
    ) throws -> String {
        try CredentialBrokerClient.requestResponse(
            socketPath: socketPath,
            token: token,
            purpose: .askPass,
            prompt: prompt
        )
    }
}

public enum ProxyCredentialClient {
    public static func requestResponse(
        socketPath: String,
        token: String,
        prompt: String
    ) throws -> String {
        try CredentialBrokerClient.requestResponse(
            socketPath: socketPath,
            token: token,
            purpose: .proxy,
            prompt: prompt
        )
    }
}

public enum CredentialBrokerClient {
    public static func requestResponse(
        socketPath: String,
        token: String,
        purpose: CredentialBrokerPurpose,
        prompt: String
    ) throws -> String {
        guard SessionCredentialBroker.isSafeSocketPath(socketPath) else {
            throw CredentialBrokerError.invalidSocketPath
        }
        guard !token.isEmpty, !token.contains("\0") else {
            throw CredentialBrokerError.invalidToken
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CredentialBrokerError.socketCreationFailed(errno)
        }
        defer {
            Darwin.close(descriptor)
        }
        guard SessionCredentialBroker.prepareConnectedSocket(descriptor) else {
            throw CredentialBrokerError.socketConfigurationFailed(errno)
        }

        var address = try SessionCredentialBroker.socketAddress(path: socketPath)
        let didConnect = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard didConnect == 0 else {
            throw CredentialBrokerError.socketConnectFailed(errno)
        }

        let request = CredentialBrokerRequest(token: token, purpose: purpose, prompt: prompt)
        try SessionCredentialBroker.writeFrame(try JSONEncoder().encode(request), to: descriptor)
        let data = try SessionCredentialBroker.readFrame(from: descriptor, maximumLength: 64 * 1024)
        let response = try JSONDecoder().decode(CredentialBrokerResponse.self, from: data)
        guard let value = response.value else {
            throw CredentialBrokerError.credentialUnavailable
        }
        return value
    }
}
