import Foundation

/// Metadata passed to the packaged proxy helper. It contains a Keychain
/// reference only, never the proxy password itself.
public struct ProxyHelperDescriptor: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sessionID: UUID
    public let proxy: ProxyConfiguration

    public init(
        version: Int = ProxyHelperDescriptor.currentVersion,
        sessionID: UUID,
        proxy: ProxyConfiguration
    ) {
        self.version = version
        self.sessionID = sessionID
        self.proxy = proxy
    }

    public var credentialPrompt: String? {
        guard let username = proxy.username, proxy.password != nil else { return nil }
        return ProxyCredentialPrompt.make(
            username: username,
            host: proxy.host,
            port: proxy.port
        )
    }

    public func encodedCommandLineValue() throws -> String {
        try validate()
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeCommandLineValue(_ value: String) throws -> ProxyHelperDescriptor {
        guard !value.isEmpty,
              value.allSatisfy({ character in
                  character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
              })
        else {
            throw ProxyHelperProtocolError.invalidEncodedDescriptor
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding
        guard let data = Data(base64Encoded: base64) else {
            throw ProxyHelperProtocolError.invalidEncodedDescriptor
        }
        let descriptor: ProxyHelperDescriptor
        do {
            descriptor = try JSONDecoder().decode(ProxyHelperDescriptor.self, from: data)
        } catch {
            throw ProxyHelperProtocolError.invalidEncodedDescriptor
        }
        guard descriptor.version == currentVersion else {
            throw ProxyHelperProtocolError.unsupportedVersion(descriptor.version)
        }
        try descriptor.validate()
        return descriptor
    }

    public func validate() throws {
        guard Self.isSafeHost(proxy.host) else {
            throw ProxyHelperProtocolError.invalidProxyHost
        }
        guard (1 ... 65_535).contains(proxy.port) else {
            throw ProxyHelperProtocolError.invalidProxyPort(proxy.port)
        }
        if let username = proxy.username {
            guard Self.isSafeUsername(username) else {
                throw ProxyHelperProtocolError.invalidProxyUsername
            }
            guard proxy.password != nil else {
                throw ProxyHelperProtocolError.proxyUsernameNeedsCredential
            }
        } else if proxy.password != nil {
            throw ProxyHelperProtocolError.proxyCredentialNeedsUsername
        }
    }

    private static func isSafeHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty
            && host == value
            && !host.hasPrefix("-")
            && !host.contains("@")
            && !host.contains(",")
            && !host.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }

    private static func isSafeUsername(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }
}

public enum ProxyHelperProtocolError: Error, Equatable, Sendable {
    case invalidEncodedDescriptor
    case unsupportedVersion(Int)
    case invalidProxyHost
    case invalidProxyPort(Int)
    case invalidProxyUsername
    case proxyUsernameNeedsCredential
    case proxyCredentialNeedsUsername
    case invalidArgument(String)
    case duplicateArgument(String)
    case missingArgument(String)
    case invalidTargetHost
    case invalidTargetPort(Int)
}

/// A stable broker prompt derived only from the helper's non-secret argv.
/// The app maps this marker to the matching Keychain value for the session.
public enum ProxyCredentialPrompt {
    public static func make(username: String, host: String, port: Int) -> String {
        "proxy:\(username.lowercased())@\(SSHInputValidator.unbracketedIPv6(host).lowercased()):\(port)"
    }
}

extension ProxyHelperProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEncodedDescriptor:
            "The proxy helper request is malformed."
        case let .unsupportedVersion(version):
            "Proxy helper protocol version \(version) is unsupported."
        case .invalidProxyHost:
            "The proxy host is invalid."
        case let .invalidProxyPort(port):
            "The proxy port \(port) is invalid."
        case .invalidProxyUsername:
            "The proxy username is invalid."
        case .proxyUsernameNeedsCredential:
            "A proxy username needs a Keychain credential reference."
        case .proxyCredentialNeedsUsername:
            "A proxy credential reference needs a username."
        case let .invalidArgument(argument):
            "The proxy helper argument \(argument) is invalid."
        case let .duplicateArgument(argument):
            "The proxy helper argument \(argument) was supplied more than once."
        case let .missingArgument(argument):
            "The proxy helper argument \(argument) is required."
        case .invalidTargetHost:
            "The proxy target host is invalid."
        case let .invalidTargetPort(port):
            "The proxy target port \(port) is invalid."
        }
    }
}

/// Exact argv contract used by the generated `ProxyCommand`. The compiler
/// renders this vector with shell quoting only at OpenSSH's required
/// ProxyCommand boundary; it never runs a shell itself.
public struct ProxyHelperInvocation: Equatable, Sendable {
    public let kind: ProxyKind
    public let proxyHost: String
    public let proxyPort: Int
    public let targetHost: String
    public let targetPort: Int
    public let credentialSocketPath: String?
    public let credentialToken: String?
    public let username: String?

    public init(
        kind: ProxyKind,
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        credentialSocketPath: String? = nil,
        credentialToken: String? = nil,
        username: String? = nil
    ) throws {
        let proxy = ProxyConfiguration(
            kind: kind,
            host: proxyHost,
            port: proxyPort,
            username: username,
            password: username == nil ? nil : SecretReference(id: UUID())
        )
        try ProxyHelperDescriptor(sessionID: UUID(), proxy: proxy).validate()
        guard (credentialSocketPath == nil) == (credentialToken == nil) else {
            throw ProxyHelperProtocolError.invalidArgument("credential socket and token")
        }
        if let credentialSocketPath {
            guard SessionCredentialBroker.isSafeSocketPath(credentialSocketPath) else {
                throw CredentialBrokerError.invalidSocketPath
            }
            guard let credentialToken, !credentialToken.isEmpty, !credentialToken.contains("\0") else {
                throw CredentialBrokerError.invalidToken
            }
            guard username != nil else {
                throw ProxyHelperProtocolError.proxyCredentialNeedsUsername
            }
        } else if username != nil {
            throw ProxyHelperProtocolError.proxyUsernameNeedsCredential
        }
        guard Self.isSafeTargetHost(targetHost) else {
            throw ProxyHelperProtocolError.invalidTargetHost
        }
        guard (1 ... 65_535).contains(targetPort) else {
            throw ProxyHelperProtocolError.invalidTargetPort(targetPort)
        }
        self.kind = kind
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.credentialSocketPath = credentialSocketPath
        self.credentialToken = credentialToken
        self.username = username
    }

    public func argumentVector(executableURL: URL) throws -> [String] {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              !executableURL.path.contains("\0"),
              !executableURL.path.unicodeScalars.contains(where: {
                  CharacterSet.newlines.union(.controlCharacters).contains($0)
              })
        else {
            throw ProxyHelperProtocolError.invalidArgument("executable")
        }
        var arguments = [
            executableURL.path,
            "--kind", kind == .httpConnect ? "http-connect" : "socks5",
            "--host", proxyHost,
            "--port", String(proxyPort),
            "--target-host", targetHost,
            "--target-port", String(targetPort)
        ]
        if let credentialSocketPath, let credentialToken, let username {
            arguments.append(contentsOf: [
                "--credential-socket", credentialSocketPath,
                "--credential-token", credentialToken,
                "--username", username
            ])
        }
        return arguments
    }

    public static func parse(arguments: [String]) throws -> ProxyHelperInvocation {
        var values: [String: String] = [:]
        var index = 0
        let validOptions: Set<String> = [
            "--kind", "--host", "--port", "--target-host", "--target-port",
            "--credential-socket", "--credential-token", "--username"
        ]

        while index < arguments.count {
            let option = arguments[index]
            guard validOptions.contains(option) else {
                throw ProxyHelperProtocolError.invalidArgument(option)
            }
            guard arguments.indices.contains(index + 1) else {
                throw ProxyHelperProtocolError.missingArgument(option)
            }
            guard values.updateValue(arguments[index + 1], forKey: option) == nil else {
                throw ProxyHelperProtocolError.duplicateArgument(option)
            }
            index += 2
        }

        func required(_ option: String) throws -> String {
            guard let value = values[option] else {
                throw ProxyHelperProtocolError.missingArgument(option)
            }
            return value
        }

        let kindValue = try required("--kind")
        let kind: ProxyKind
        switch kindValue {
        case "http-connect": kind = .httpConnect
        case "socks5": kind = .socks5
        default: throw ProxyHelperProtocolError.invalidArgument("--kind")
        }
        let proxyPortValue = try required("--port")
        guard let proxyPort = Int(proxyPortValue) else {
            throw ProxyHelperProtocolError.invalidArgument("--port")
        }
        let targetPortValue = try required("--target-port")
        guard let targetPort = Int(targetPortValue) else {
            throw ProxyHelperProtocolError.invalidArgument("--target-port")
        }
        return try ProxyHelperInvocation(
            kind: kind,
            proxyHost: required("--host"),
            proxyPort: proxyPort,
            targetHost: required("--target-host"),
            targetPort: targetPort,
            credentialSocketPath: values["--credential-socket"],
            credentialToken: values["--credential-token"],
            username: values["--username"]
        )
    }

    private static func isSafeTargetHost(_ host: String) -> Bool {
        !host.isEmpty
            && !host.hasPrefix("-")
            && !host.contains("@")
            && !host.contains(",")
            && !host.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }
}

public struct ProxyHelperLaunchConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let socketPath: String?
    public let token: String?
    public let sessionID: UUID

    public init(
        executableURL: URL,
        socketPath: String? = nil,
        token: String? = nil,
        sessionID: UUID = UUID()
    ) {
        self.executableURL = executableURL
        self.socketPath = socketPath
        self.token = token
        self.sessionID = sessionID
    }

    public static func packaged(appBundleURL: URL, broker: SessionCredentialBroker, sessionID: UUID = UUID()) -> Self {
        Self(
            executableURL: appBundleURL.appendingPathComponent("Contents/MacOS/osXtermProxy"),
            socketPath: broker.socketPath,
            token: broker.token,
            sessionID: sessionID
        )
    }
}
