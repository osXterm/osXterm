import Darwin
import Foundation
import OsXtermCore

private enum ProxyHelperError: Error {
    case invalidArguments
    case invalidEndpoint
    case connectionFailed
    case handshakeFailed
    case authenticationUnavailable
    case ioFailed
}

private enum ProxyHelperKind: String {
    case httpConnect = "http-connect"
    case socks5
}

private struct ProxyArguments {
    let kind: ProxyHelperKind
    let proxyHost: String
    let proxyPort: Int
    let targetHost: String
    let targetPort: Int
    let credentialSocket: String?
    let credentialToken: String?
    let username: String?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw ProxyHelperError.invalidArguments
            }
            let value = arguments[index + 1]
            guard values[key] == nil else { throw ProxyHelperError.invalidArguments }
            values[key] = value
            index += 2
        }

        guard let kindValue = values["--kind"],
              let kind = ProxyHelperKind(rawValue: kindValue),
              let proxyHost = values["--host"],
              let proxyPort = Int(values["--port"] ?? ""),
              let targetHost = values["--target-host"],
              let targetPort = Int(values["--target-port"] ?? ""),
              Self.isSafeHost(proxyHost),
              Self.isSafeHost(targetHost),
              (1...65_535).contains(proxyPort),
              (1...65_535).contains(targetPort)
        else {
            throw ProxyHelperError.invalidArguments
        }

        let credentialSocket = values["--credential-socket"]
        let credentialToken = values["--credential-token"]
        let username = values["--username"]
        if let username, !Self.isSafeUser(username) {
            throw ProxyHelperError.invalidArguments
        }
        if (credentialSocket == nil) != (credentialToken == nil) {
            throw ProxyHelperError.invalidArguments
        }
        if username != nil, credentialSocket == nil {
            throw ProxyHelperError.invalidArguments
        }

        self.kind = kind
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.credentialSocket = credentialSocket
        self.credentialToken = credentialToken
        self.username = username
    }

    private static func isSafeHost(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }

    private static func isSafeUser(_ value: String) -> Bool {
        !value.isEmpty
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }
}

private func connectSocket(host: String, port: Int) throws -> Int32 {
    var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var first: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &first) == 0, let result = first else {
        throw ProxyHelperError.connectionFailed
    }
    defer { freeaddrinfo(result) }

    var cursor: UnsafeMutablePointer<addrinfo>? = result
    while let candidate = cursor {
        let info = candidate.pointee
        let descriptor = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        if descriptor >= 0 {
            if Darwin.connect(descriptor, info.ai_addr, info.ai_addrlen) == 0 {
                return descriptor
            }
            Darwin.close(descriptor)
        }
        cursor = info.ai_next
    }
    throw ProxyHelperError.connectionFailed
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.send(descriptor, pointer, remaining, 0)
            if count > 0 {
                remaining -= Int(count)
                pointer = pointer.advanced(by: Int(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw ProxyHelperError.ioFailed
            }
        }
    }
}

private func writeAllToStandardOutput(_ data: Data) throws {
    try data.withUnsafeBytes { buffer in
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.write(STDOUT_FILENO, pointer, remaining)
            if count > 0 {
                remaining -= Int(count)
                pointer = pointer.advanced(by: Int(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw ProxyHelperError.ioFailed
            }
        }
    }
}

private func readExactly(_ length: Int, from descriptor: Int32) throws -> Data {
    var result = Data(count: length)
    try result.withUnsafeMutableBytes { buffer in
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.read(descriptor, pointer, remaining)
            if count > 0 {
                remaining -= Int(count)
                pointer = pointer.advanced(by: Int(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw ProxyHelperError.ioFailed
            }
        }
    }
    return result
}

private func credential(for arguments: ProxyArguments) throws -> String? {
    guard let socket = arguments.credentialSocket,
          let token = arguments.credentialToken,
          let username = arguments.username
    else {
        return nil
    }
    return try ProxyCredentialClient.requestResponse(
        socketPath: socket,
        token: token,
        prompt: ProxyCredentialPrompt.make(
            username: username,
            host: arguments.proxyHost,
            port: arguments.proxyPort
        )
    )
}

private func httpAuthority(host: String, port: Int) -> String {
    let normalizedHost = host.hasPrefix("[") ? host : (host.contains(":") ? "[\(host)]" : host)
    return "\(normalizedHost):\(port)"
}

private func performHTTPConnect(arguments: ProxyArguments, socket: Int32) throws -> Data {
    let authority = httpAuthority(host: arguments.targetHost, port: arguments.targetPort)
    var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Connection: Keep-Alive\r\n"
    if let username = arguments.username {
        guard let password = try credential(for: arguments) else {
            throw ProxyHelperError.authenticationUnavailable
        }
        let authorization = Data("\(username):\(password)".utf8).base64EncodedString()
        request += "Proxy-Authorization: Basic \(authorization)\r\n"
    }
    request += "\r\n"
    try writeAll(Data(request.utf8), to: socket)

    let boundary = Data([0x0D, 0x0A, 0x0D, 0x0A])
    var response = Data()
    while response.count <= 32 * 1024 {
        let next = try readExactly(1, from: socket)
        response.append(next)
        if response.suffix(boundary.count) == boundary { break }
    }
    guard let boundaryRange = response.range(of: boundary),
          let header = String(data: response[..<boundaryRange.lowerBound], encoding: .ascii),
          let statusLine = header.split(separator: "\r\n", maxSplits: 1).first,
          statusLine.hasPrefix("HTTP/"),
          let codeToken = statusLine.split(separator: " ").dropFirst().first,
          let statusCode = Int(codeToken),
          (200...299).contains(statusCode)
    else {
        throw ProxyHelperError.handshakeFailed
    }
    return Data(response[boundaryRange.upperBound...])
}

private func performSOCKS5(arguments: ProxyArguments, socket: Int32) throws {
    let methods: [UInt8] = arguments.username == nil ? [0x00] : [0x00, 0x02]
    try writeAll(Data([0x05, UInt8(methods.count)] + methods), to: socket)
    let methodReply = [UInt8](try readExactly(2, from: socket))
    guard methodReply.count == 2, methodReply[0] == 0x05 else {
        throw ProxyHelperError.handshakeFailed
    }
    if methodReply[1] == 0x02 {
        guard let username = arguments.username,
              let password = try credential(for: arguments)
        else {
            throw ProxyHelperError.authenticationUnavailable
        }
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        guard !usernameBytes.isEmpty, usernameBytes.count <= 255, passwordBytes.count <= 255 else {
            throw ProxyHelperError.invalidArguments
        }
        var auth = Data([0x01, UInt8(usernameBytes.count)])
        auth.append(contentsOf: usernameBytes)
        auth.append(UInt8(passwordBytes.count))
        auth.append(contentsOf: passwordBytes)
        try writeAll(auth, to: socket)
        let authReply = [UInt8](try readExactly(2, from: socket))
        guard authReply.count == 2, authReply[0] == 0x01, authReply[1] == 0x00 else {
            throw ProxyHelperError.handshakeFailed
        }
    } else if methodReply[1] != 0x00 {
        throw ProxyHelperError.handshakeFailed
    }

    var request = Data([0x05, 0x01, 0x00])
    var address4 = in_addr()
    var address6 = in6_addr()
    if inet_pton(AF_INET, arguments.targetHost, &address4) == 1 {
        request.append(0x01)
        request.append(Data(bytes: &address4, count: MemoryLayout<in_addr>.size))
    } else if inet_pton(AF_INET6, arguments.targetHost, &address6) == 1 {
        request.append(0x04)
        request.append(Data(bytes: &address6, count: MemoryLayout<in6_addr>.size))
    } else {
        let bytes = Array(arguments.targetHost.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else { throw ProxyHelperError.invalidEndpoint }
        request.append(0x03)
        request.append(UInt8(bytes.count))
        request.append(contentsOf: bytes)
    }
    var port = UInt16(arguments.targetPort).bigEndian
    request.append(Data(bytes: &port, count: MemoryLayout<UInt16>.size))
    try writeAll(request, to: socket)

    let response = [UInt8](try readExactly(4, from: socket))
    guard response.count == 4, response[0] == 0x05, response[1] == 0x00 else {
        throw ProxyHelperError.handshakeFailed
    }
    let trailingLength: Int
    switch response[3] {
    case 0x01: trailingLength = 4 + 2
    case 0x04: trailingLength = 16 + 2
    case 0x03:
        let length = [UInt8](try readExactly(1, from: socket))
        guard let first = length.first else { throw ProxyHelperError.handshakeFailed }
        trailingLength = Int(first) + 2
    default:
        throw ProxyHelperError.handshakeFailed
    }
    _ = try readExactly(trailingLength, from: socket)
}

private func relay(socket: Int32, initialOutput: Data = Data()) throws {
    if !initialOutput.isEmpty {
        try writeAllToStandardOutput(initialOutput)
    }

    var stdinOpen = true
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while stdinOpen {
        var descriptors = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        ]
        let pollResult = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
        if pollResult < 0 {
            if errno == EINTR { continue }
            throw ProxyHelperError.ioFailed
        }

        if descriptors[0].revents & Int16(POLLIN) != 0 {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                try writeAll(Data(buffer[0 ..< Int(count)]), to: socket)
            } else if count == 0 {
                stdinOpen = false
                _ = Darwin.shutdown(socket, SHUT_WR)
            } else if errno != EINTR {
                throw ProxyHelperError.ioFailed
            }
        }

        if descriptors[1].revents & (Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR)) != 0 {
            let count = Darwin.read(socket, &buffer, buffer.count)
            if count > 0 {
                try writeAllToStandardOutput(Data(buffer[0 ..< Int(count)]))
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw ProxyHelperError.ioFailed
            }
        }
    }
}

private func run() throws {
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
    let arguments = try ProxyArguments(arguments: Array(CommandLine.arguments.dropFirst()))
    let socket = try connectSocket(host: arguments.proxyHost, port: arguments.proxyPort)
    defer { Darwin.close(socket) }

    switch arguments.kind {
    case .httpConnect:
        let initialOutput = try performHTTPConnect(arguments: arguments, socket: socket)
        try relay(socket: socket, initialOutput: initialOutput)
    case .socks5:
        try performSOCKS5(arguments: arguments, socket: socket)
        try relay(socket: socket)
    }
}

do {
    try run()
    exit(EXIT_SUCCESS)
} catch {
    // ProxyCommand has no safe structured error channel. Keep diagnostics
    // secret-free and let OpenSSH surface the connection failure to the app.
    FileHandle.standardError.write(Data("osXterm proxy connection failed\n".utf8))
    exit(EXIT_FAILURE)
}
