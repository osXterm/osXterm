import Foundation

/// Bidirectional byte transport for an `ssh -s sftp` subsystem channel.
/// Production code owns the SSH process or channel; this client owns only the
/// structured SFTP protocol and can therefore be tested without shell output.
public protocol SFTPByteTransport: Sendable {
    func send(_ bytes: Data) async throws
    func receive() async throws -> Data?
    func close() async
}

public enum SFTPClientError: Error, Equatable, Sendable, LocalizedError {
    case handshakeRequired
    case invalidHandshake(SFTPResponse)
    case transportClosed
    case unexpectedResponse(requestID: UInt32, response: SFTPResponse)
    case remoteStatus(requestID: UInt32, status: SFTPStatus, message: String)

    public var errorDescription: String? {
        switch self {
        case .handshakeRequired:
            "SFTP initialization must complete before requests are sent."
        case let .invalidHandshake(response):
            "SFTP server sent an invalid initialization response: \(response)"
        case .transportClosed:
            "SFTP transport closed before a complete response was received."
        case let .unexpectedResponse(requestID, response):
            "SFTP request \(requestID) received an unexpected response: \(response)"
        case let .remoteStatus(requestID, status, message):
            "SFTP request \(requestID) failed with status \(status.rawValue): \(message)"
        }
    }
}

public struct SFTPServerCapabilities: Equatable, Sendable {
    public let version: UInt32
    public let extensions: [String: String]

    public init(version: UInt32, extensions: [String: String]) {
        self.version = version
        self.extensions = extensions
    }
}

public struct SFTPHandle: Equatable, Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

/// Serialized SFTP v3 client. The actor issues one request at a time, while
/// still preserving unrelated frames so a transport can safely deliver chunks
/// containing more than one response.
public actor SFTPClient {
    private let transport: any SFTPByteTransport
    private var streamDecoder: SFTPStreamDecoder
    private var nextRequestID: UInt32 = 1
    private var capabilities: SFTPServerCapabilities?
    private var pendingResponses: [UInt32: [SFTPResponse]] = [:]

    public init(
        transport: any SFTPByteTransport,
        maximumPacketLength: Int = SFTPCodec.defaultMaximumPacketLength
    ) {
        self.transport = transport
        streamDecoder = SFTPStreamDecoder(maximumPacketLength: maximumPacketLength)
    }

    public func initialize() async throws -> SFTPServerCapabilities {
        if let capabilities { return capabilities }

        try await transport.send(SFTPCodec.encode(.initialize()))
        while true {
            let frame = try await nextFrame()
            let response = try SFTPCodec.decodeResponse(frame)
            guard case let .version(version, extensions) = response else {
                throw SFTPClientError.invalidHandshake(response)
            }
            let capabilities = SFTPServerCapabilities(version: version, extensions: extensions)
            self.capabilities = capabilities
            return capabilities
        }
    }

    public func open(
        path: SFTPRemotePath,
        flags: SFTPOpenFlags,
        attributes: SFTPFileAttributes = SFTPFileAttributes()
    ) async throws -> SFTPHandle {
        let response = try await perform { requestID in
            .open(requestID: requestID, path: path, flags: flags, attributes: attributes)
        }
        switch response {
        case let .handle(_, handle):
            return SFTPHandle(bytes: handle)
        case let .status(requestID, status, message, _):
            throw SFTPClientError.remoteStatus(requestID: requestID, status: status, message: message)
        default:
            throw SFTPClientError.unexpectedResponse(
                requestID: response.associatedRequestID ?? 0,
                response: response
            )
        }
    }

    public func close(_ handle: SFTPHandle) async throws {
        let response = try await perform { requestID in
            .close(requestID: requestID, handle: handle.bytes)
        }
        try requireOK(response)
    }

    public func read(
        from handle: SFTPHandle,
        offset: UInt64,
        length: UInt32
    ) async throws -> Data? {
        let response = try await perform { requestID in
            .read(requestID: requestID, handle: handle.bytes, offset: offset, length: length)
        }
        switch response {
        case let .data(_, data):
            return data
        case let .status(_, status, _, _) where status == .endOfFile:
            return nil
        case let .status(requestID, status, message, _):
            throw SFTPClientError.remoteStatus(requestID: requestID, status: status, message: message)
        default:
            throw SFTPClientError.unexpectedResponse(
                requestID: response.associatedRequestID ?? 0,
                response: response
            )
        }
    }

    public func write(
        _ data: Data,
        to handle: SFTPHandle,
        offset: UInt64
    ) async throws {
        let response = try await perform { requestID in
            .write(requestID: requestID, handle: handle.bytes, offset: offset, data: data)
        }
        try requireOK(response)
    }

    public func attributes(of path: SFTPRemotePath, followSymlink: Bool = true) async throws -> SFTPFileAttributes {
        let response = try await perform { requestID in
            followSymlink
                ? .stat(requestID: requestID, path: path)
                : .lstat(requestID: requestID, path: path)
        }
        switch response {
        case let .attributes(_, attributes):
            return attributes
        case let .status(requestID, status, message, _):
            throw SFTPClientError.remoteStatus(requestID: requestID, status: status, message: message)
        default:
            throw SFTPClientError.unexpectedResponse(
                requestID: response.associatedRequestID ?? 0,
                response: response
            )
        }
    }

    public func openDirectory(_ path: SFTPRemotePath) async throws -> SFTPHandle {
        let response = try await perform { requestID in
            .openDirectory(requestID: requestID, path: path)
        }
        switch response {
        case let .handle(_, handle):
            return SFTPHandle(bytes: handle)
        case let .status(requestID, status, message, _):
            throw SFTPClientError.remoteStatus(requestID: requestID, status: status, message: message)
        default:
            throw SFTPClientError.unexpectedResponse(
                requestID: response.associatedRequestID ?? 0,
                response: response
            )
        }
    }

    public func listDirectory(_ path: SFTPRemotePath) async throws -> [SFTPNameEntry] {
        let handle = try await openDirectory(path)
        var entries: [SFTPNameEntry] = []

        do {
            while true {
                let response = try await perform { requestID in
                    .readDirectory(requestID: requestID, handle: handle.bytes)
                }
                switch response {
                case let .name(_, page):
                    entries.append(contentsOf: page)
                case let .status(_, status, _, _) where status == .endOfFile:
                    try await close(handle)
                    return entries
                case let .status(requestID, status, message, _):
                    throw SFTPClientError.remoteStatus(requestID: requestID, status: status, message: message)
                default:
                    throw SFTPClientError.unexpectedResponse(
                        requestID: response.associatedRequestID ?? 0,
                        response: response
                    )
                }
            }
        } catch {
            try? await close(handle)
            throw error
        }
    }

    public func remove(_ path: SFTPRemotePath) async throws {
        let response = try await perform { requestID in
            .remove(requestID: requestID, path: path)
        }
        try requireOK(response)
    }

    public func removeDirectory(_ path: SFTPRemotePath) async throws {
        let response = try await perform { requestID in
            .removeDirectory(requestID: requestID, path: path)
        }
        try requireOK(response)
    }

    public func makeDirectory(
        _ path: SFTPRemotePath,
        attributes: SFTPFileAttributes = SFTPFileAttributes()
    ) async throws {
        let response = try await perform { requestID in
            .makeDirectory(requestID: requestID, path: path, attributes: attributes)
        }
        try requireOK(response)
    }

    public func rename(from: SFTPRemotePath, to: SFTPRemotePath) async throws {
        let response = try await perform { requestID in
            .rename(requestID: requestID, from: from, to: to)
        }
        try requireOK(response)
    }

    public func setAttributes(
        _ attributes: SFTPFileAttributes,
        for path: SFTPRemotePath
    ) async throws {
        let response = try await perform { requestID in
            .setstat(requestID: requestID, path: path, attributes: attributes)
        }
        try requireOK(response)
    }

    public func symbolicLinkTarget(at path: SFTPRemotePath) async throws -> String {
        let response = try await perform { requestID in
            .readLink(requestID: requestID, path: path)
        }
        switch response {
        case let .name(_, entries):
            guard let first = entries.first else {
                throw SFTPClientError.unexpectedResponse(
                    requestID: response.associatedRequestID ?? 0,
                    response: response
                )
            }
            return first.filename
        case let .status(requestID, status, message, _):
            throw SFTPClientError.remoteStatus(requestID: requestID, status: status, message: message)
        default:
            throw SFTPClientError.unexpectedResponse(
                requestID: response.associatedRequestID ?? 0,
                response: response
            )
        }
    }

    public func createSymbolicLink(
        at linkPath: SFTPRemotePath,
        pointingTo targetPath: SFTPRemotePath
    ) async throws {
        let response = try await perform { requestID in
            .symlink(requestID: requestID, linkPath: linkPath, targetPath: targetPath)
        }
        try requireOK(response)
    }

    public func disconnect() async {
        await transport.close()
    }

    private func perform(
        _ request: (UInt32) throws -> SFTPRequest
    ) async throws -> SFTPResponse {
        guard capabilities != nil else {
            throw SFTPClientError.handshakeRequired
        }
        let requestID = consumeRequestID()
        try await transport.send(SFTPCodec.encode(try request(requestID)))
        return try await response(for: requestID)
    }

    private func consumeRequestID() -> UInt32 {
        let result = nextRequestID
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }
        return result
    }

    private func response(for requestID: UInt32) async throws -> SFTPResponse {
        if var pending = pendingResponses[requestID], !pending.isEmpty {
            let result = pending.removeFirst()
            pendingResponses[requestID] = pending.isEmpty ? nil : pending
            return result
        }

        while true {
            let frame = try await nextFrame()
            let response = try SFTPCodec.decodeResponse(frame)
            guard let responseID = response.associatedRequestID else {
                throw SFTPClientError.invalidHandshake(response)
            }
            if responseID == requestID {
                return response
            }
            pendingResponses[responseID, default: []].append(response)
        }
    }

    private func nextFrame() async throws -> SFTPFrame {
        while true {
            guard let bytes = try await transport.receive() else {
                throw SFTPClientError.transportClosed
            }
            let frames = try streamDecoder.append(bytes)
            if let first = frames.first {
                for frame in frames.dropFirst() {
                    let response = try SFTPCodec.decodeResponse(frame)
                    if let requestID = response.associatedRequestID {
                        pendingResponses[requestID, default: []].append(response)
                    } else {
                        throw SFTPClientError.invalidHandshake(response)
                    }
                }
                return first
            }
        }
    }

    private func requireOK(_ response: SFTPResponse) throws {
        guard case let .status(requestID, status, message, _) = response else {
            throw SFTPClientError.unexpectedResponse(
                requestID: response.associatedRequestID ?? 0,
                response: response
            )
        }
        guard status == .ok else {
            throw SFTPClientError.remoteStatus(requestID: requestID, status: status, message: message)
        }
    }
}

private extension SFTPResponse {
    var associatedRequestID: UInt32? {
        switch self {
        case .version:
            return nil
        case let .status(requestID, _, _, _),
             let .handle(requestID, _),
             let .data(requestID, _),
             let .name(requestID, _),
             let .attributes(requestID, _),
             let .extendedReply(requestID, _):
            return requestID
        }
    }
}
