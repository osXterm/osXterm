import Darwin
import Dispatch
import Foundation

/// Errors raised by the in-memory AskPass bridge used for one active session.
public enum SessionAskPassError: Error, Equatable, Sendable {
    case emptyCredential
    case invalidSocketPath
    case socketCreationFailed(Int32)
    case socketBindFailed(Int32)
    case socketListenFailed(Int32)
    case socketConnectFailed(Int32)
    case socketReadFailed(Int32)
    case responseTooLarge
}

extension SessionAskPassError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "A password is required for this connection."
        case .invalidSocketPath:
            "The temporary AskPass socket path is invalid."
        case let .socketCreationFailed(status):
            "Could not create the temporary AskPass socket (errno \(status))."
        case let .socketBindFailed(status):
            "Could not bind the temporary AskPass socket (errno \(status))."
        case let .socketListenFailed(status):
            "Could not listen on the temporary AskPass socket (errno \(status))."
        case let .socketConnectFailed(status):
            "Could not reach the temporary AskPass socket (errno \(status))."
        case let .socketReadFailed(status):
            "Could not read the temporary AskPass response (errno \(status))."
        case .responseTooLarge:
            "The temporary AskPass response is too large."
        }
    }
}

/// Supplies an SSH password from process memory to the short-lived AskPass helper.
///
/// The server uses a random Unix-domain socket inside a mode 0700 directory. The
/// Plaintext password bytes are never written to an environment variable or
/// temporary file. They are discarded when the active session ends.
public final class SessionAskPassServer: @unchecked Sendable {
    public let socketPath: String

    private let directoryURL: URL
    private let listenerFileDescriptor: Int32
    private let eventSource: DispatchSourceRead
    private let queue = DispatchQueue(label: "com.one393.osXterm.askpass")
    private let credentialLock = NSLock()
    private let lifecycleLock = NSLock()
    private var credentials: [String: Data]
    private var isStopped = false

    public convenience init(credential: String) throws {
        try self.init(credentials: ["default": credential])
    }

    public init(credentials: [String: String]) throws {
        let nonEmpty = credentials.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard !nonEmpty.isEmpty else {
            throw SessionAskPassError.emptyCredential
        }

        let directoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("osXterm-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let socketPath = directoryURL.appendingPathComponent("credential.sock").path
        guard Self.isValidSocketPath(socketPath) else {
            try? FileManager.default.removeItem(at: directoryURL)
            throw SessionAskPassError.invalidSocketPath
        }

        let listenerFileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFileDescriptor >= 0 else {
            let status = errno
            try? FileManager.default.removeItem(at: directoryURL)
            throw SessionAskPassError.socketCreationFailed(status)
        }

        var shouldCloseListener = true
        defer {
            if shouldCloseListener {
                Darwin.close(listenerFileDescriptor)
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        var address = try Self.socketAddress(path: socketPath)
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listenerFileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindStatus == 0 else {
            throw SessionAskPassError.socketBindFailed(errno)
        }

        let permissionStatus = socketPath.withCString { path in
            Darwin.chmod(path, mode_t(0o600))
        }
        guard permissionStatus == 0 else {
            throw SessionAskPassError.socketBindFailed(errno)
        }

        guard Darwin.listen(listenerFileDescriptor, SOMAXCONN) == 0 else {
            throw SessionAskPassError.socketListenFailed(errno)
        }

        let existingFlags = Darwin.fcntl(listenerFileDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = Darwin.fcntl(listenerFileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
        }

        let eventSource = DispatchSource.makeReadSource(
            fileDescriptor: listenerFileDescriptor,
            queue: queue
        )

        self.socketPath = socketPath
        self.directoryURL = directoryURL
        self.listenerFileDescriptor = listenerFileDescriptor
        self.credentials = nonEmpty.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = Data(pair.value.utf8)
        }
        self.eventSource = eventSource

        eventSource.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        eventSource.setCancelHandler {
            Darwin.close(listenerFileDescriptor)
        }
        eventSource.resume()
        shouldCloseListener = false
    }

    deinit {
        stop()
    }

    public func stop() {
        lifecycleLock.lock()
        guard !isStopped else {
            lifecycleLock.unlock()
            return
        }
        isStopped = true
        lifecycleLock.unlock()

        clearCredential()
        eventSource.cancel()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func acceptConnections() {
        while true {
            let clientFileDescriptor = Darwin.accept(listenerFileDescriptor, nil, nil)
            guard clientFileDescriptor >= 0 else {
                let status = errno
                if status == EAGAIN || status == EWOULDBLOCK {
                    return
                }
                return
            }
            sendCredential(to: clientFileDescriptor)
        }
    }

    private func sendCredential(to clientFileDescriptor: Int32) {
        defer {
            _ = Darwin.shutdown(clientFileDescriptor, SHUT_WR)
            Darwin.close(clientFileDescriptor)
        }

        let prompt = Self.readPrompt(from: clientFileDescriptor)
        guard var response = credentialData(for: prompt) else {
            return
        }
        defer {
            response.resetBytes(in: 0 ..< response.count)
        }

        response.append(contentsOf: [0x0A])
        Self.write(response, to: clientFileDescriptor)
    }

    private func credentialData(for prompt: String) -> Data? {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        let normalizedPrompt = prompt.lowercased()
        if let exact = credentials.first(where: {
            normalizedPrompt.contains($0.key)
        }) {
            return exact.value
        }
        return credentials.count == 1 ? credentials.values.first : nil
    }

    private func clearCredential() {
        credentialLock.lock()
        defer { credentialLock.unlock() }

        for key in Array(credentials.keys) {
            guard var value = credentials[key] else { continue }
            value.resetBytes(in: 0 ..< value.count)
            credentials[key] = value
        }
        credentials.removeAll()
    }

    private static func readPrompt(from fileDescriptor: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count < 4096 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(Int(count)))
            if data.contains(0x0A) { break }
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func write(_ data: Data, to fileDescriptor: Int32) {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else {
                return
            }
            var remaining = buffer.count

            while remaining > 0 {
                let bytesWritten = Darwin.write(fileDescriptor, pointer, remaining)
                if bytesWritten > 0 {
                    remaining -= Int(bytesWritten)
                    pointer = pointer.advanced(by: Int(bytesWritten))
                } else if bytesWritten == -1, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    fileprivate static func socketAddress(path: String) throws -> sockaddr_un {
        guard isValidSocketPath(path) else {
            throw SessionAskPassError.invalidSocketPath
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    fileprivate static func isValidSocketPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.contains("\0")
            && path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }
}

/// Connects the AskPass executable to an active session's in-memory credential.
public enum SessionAskPassClient {
    public static func readCredential(
        socketPath: String,
        prompt: String = ""
    ) throws -> Data {
        guard SessionAskPassServer.isValidSocketPath(socketPath) else {
            throw SessionAskPassError.invalidSocketPath
        }

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw SessionAskPassError.socketCreationFailed(errno)
        }
        defer {
            Darwin.close(fileDescriptor)
        }

        var address = try SessionAskPassServer.socketAddress(path: socketPath)
        let connectStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connectStatus == 0 else {
            throw SessionAskPassError.socketConnectFailed(errno)
        }

        let request = Data((prompt + "\n").utf8)
        SessionAskPassServer.write(request, to: fileDescriptor)
        _ = Darwin.shutdown(fileDescriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        let maximumResponseLength = 16 * 1024

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { buffer in
                Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if bytesRead > 0 {
                response.append(contentsOf: buffer.prefix(Int(bytesRead)))
                if response.count > maximumResponseLength {
                    throw SessionAskPassError.responseTooLarge
                }
                continue
            }
            if bytesRead == 0 {
                return response
            }
            if errno == EINTR {
                continue
            }
            throw SessionAskPassError.socketReadFailed(errno)
        }
    }
}
