import Foundation

/// A shell-free invocation of the system SSH client.
public struct SSHCommand: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environmentOverrides: [String: String]
    public var requiresAskPass: Bool

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        requiresAskPass: Bool = false
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
        self.requiresAskPass = requiresAskPass
    }
}

public enum SSHCommandMode: Equatable, Sendable {
    case interactive
}

public struct SSHCommandOptions: Equatable, Sendable {
    public var mode: SSHCommandMode
    public var connectTimeout: Int?
    public var serverAliveInterval: Int?
    public var serverAliveCountMax: Int?

    public init(
        mode: SSHCommandMode = .interactive,
        connectTimeout: Int? = 15,
        serverAliveInterval: Int? = 30,
        serverAliveCountMax: Int? = 3
    ) {
        self.mode = mode
        self.connectTimeout = connectTimeout
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
    }
}

public enum SSHCommandBuilderError: Error, Equatable, Sendable {
    case invalidHost(context: String)
    case invalidUsername(context: String)
    case invalidPort(port: Int, context: String)
    case invalidPath(context: String)
    case invalidOption(name: String, value: Int)
    case unresolvedJumpRoute
    case unsupportedProxy
}

extension SSHCommandBuilderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidHost(context):
            "Invalid or unsafe host value for \(context)."
        case let .invalidUsername(context):
            "Invalid or unsafe username for \(context)."
        case let .invalidPort(port, context):
            "Port \(port) is outside 1...65535 for \(context)."
        case .invalidPath:
            "An SSH identity or agent socket path is empty or contains a null byte."
        case let .invalidOption(name, value):
            "SSH option \(name) has invalid value \(value)."
        case .unresolvedJumpRoute:
            "The Jump Host route must be resolved from saved profiles before connecting."
        case .unsupportedProxy:
            "The profile requires a proxy bridge, but no safe proxy transport was supplied."
        }
    }
}

/// Builds deterministic `/usr/bin/ssh` invocations from saved profiles.
public struct SSHCommandBuilder: Sendable {
    public var executableURL: URL
    public var options: SSHCommandOptions

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        options: SSHCommandOptions = SSHCommandOptions()
    ) {
        self.executableURL = executableURL
        self.options = options
    }

    /// Builds a direct connection. A profile with Jump Host references must be
    /// passed through `build(route:configuration:)` so the live references are
    /// validated before OpenSSH is launched.
    public func build(for profile: SSHProfile) throws -> SSHCommand {
        guard profile.jumpHostProfileIDs.isEmpty else {
            throw SSHCommandBuilderError.unresolvedJumpRoute
        }
        let route = ResolvedSSHRoute(hops: [], target: profile)
        return try build(route: route, configuration: nil)
    }

    public func build(
        route: ResolvedSSHRoute,
        configuration: SSHRouteConfiguration?
    ) throws -> SSHCommand {
        try validateOptions()
        if configuration == nil, !route.hops.isEmpty {
            throw SSHCommandBuilderError.unresolvedJumpRoute
        }
        try validate(profile: route.target, context: "target")
        for hop in route.hops {
            try validate(profile: hop, context: "jump host")
        }

        var arguments: [String] = []
        var environmentOverrides: [String: String] = [:]

        arguments.append(contentsOf: [
            "-o", "StrictHostKeyChecking=accept-new"
        ])
        if let connectTimeout = options.connectTimeout {
            arguments.append(contentsOf: ["-o", "ConnectTimeout=\(connectTimeout)"])
        }
        if let serverAliveInterval = options.serverAliveInterval {
            arguments.append(contentsOf: ["-o", "ServerAliveInterval=\(serverAliveInterval)"])
        }
        if let serverAliveCountMax = options.serverAliveCountMax {
            arguments.append(contentsOf: ["-o", "ServerAliveCountMax=\(serverAliveCountMax)"])
        }

        if let configuration {
            guard configuration.fileURL.isFileURL else {
                throw SSHCommandBuilderError.invalidPath(context: configuration.fileURL.path)
            }
            arguments += ["-F", configuration.fileURL.path]
            arguments.append(route.target.agentForwarding ? "-A" : "-a")
            arguments += ["-tt", configuration.targetAlias]
        } else {
            let target = try targetValues(route.target)
            arguments += [
                "-p", String(route.target.port),
                "-l", target.username,
                route.target.agentForwarding ? "-A" : "-a",
                "-o", "ProxyJump=none"
            ]
            if let proxy = route.target.proxy {
                arguments += ["-o", "ProxyCommand=\(try Self.proxyCommand(proxy))"]
            } else {
                arguments += ["-o", "ProxyCommand=none"]
            }
            switch route.target.authentication {
            case let .agent(socketPath):
                arguments += [
                    "-o", "PreferredAuthentications=publickey",
                    "-o", "PasswordAuthentication=no",
                    "-o", "KbdInteractiveAuthentication=no"
                ]
                if let socketPath {
                    try Self.validatePath(socketPath)
                    arguments += ["-o", "IdentityAgent=SSH_AUTH_SOCK"]
                    environmentOverrides["SSH_AUTH_SOCK"] = socketPath
                }
            case let .identityFile(path):
                try Self.validatePath(path)
                arguments += [
                    "-i", path,
                    "-o", "IdentitiesOnly=yes",
                    "-o", "PreferredAuthentications=publickey",
                    "-o", "PasswordAuthentication=no",
                    "-o", "KbdInteractiveAuthentication=no"
                ]
            case .password:
                arguments += [
                    "-o", "PreferredAuthentications=keyboard-interactive,password",
                    "-o", "PubkeyAuthentication=no",
                    "-o", "NumberOfPasswordPrompts=1"
                ]
            }
            arguments += ["-tt", Self.unbracketedHost(target.host)]
        }

        return SSHCommand(
            executableURL: executableURL,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            requiresAskPass: route.profiles.contains {
                if case .password = $0.authentication { return true }
                return false
            }
        )
    }

    private func validateOptions() throws {
        if let value = options.connectTimeout, value <= 0 {
            throw SSHCommandBuilderError.invalidOption(name: "ConnectTimeout", value: value)
        }
        if let value = options.serverAliveInterval, value < 0 {
            throw SSHCommandBuilderError.invalidOption(name: "ServerAliveInterval", value: value)
        }
        if let value = options.serverAliveCountMax, value < 0 {
            throw SSHCommandBuilderError.invalidOption(name: "ServerAliveCountMax", value: value)
        }
    }

    private func validate(profile: SSHProfile, context: String) throws {
        let values = try targetValues(profile)
        try Self.validateHost(values.host, context: context)
        try Self.validateUsername(values.username, context: context)
        try Self.validatePort(profile.port, context: context)

        switch profile.authentication {
        case let .agent(socketPath):
            if let socketPath { try Self.validatePath(socketPath) }
        case let .identityFile(path):
            try Self.validatePath(path)
        case .password:
            break
        }
    }

    private func targetValues(_ profile: SSHProfile) throws -> (host: String, username: String) {
        guard let target = SSHConnectionTarget.parse(
            host: profile.host,
            username: profile.username
        ) else {
            if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SSHCommandBuilderError.invalidHost(context: "target")
            }
            throw SSHCommandBuilderError.invalidUsername(context: "target")
        }
        return (target.host, target.username)
    }

    private static func validateHost(_ host: String, context: String) throws {
        let unbracketed = unbracketedHost(host)
        guard !unbracketed.isEmpty,
              !unbracketed.hasPrefix("-"),
              !unbracketed.contains("@"),
              !unbracketed.contains(","),
              !unbracketed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }),
              bracketsAreBalanced(host)
        else {
            throw SSHCommandBuilderError.invalidHost(context: context)
        }
    }

    private static func validateUsername(_ username: String, context: String) throws {
        guard !username.isEmpty,
              !username.hasPrefix("-"),
              !username.contains(","),
              !username.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              })
        else {
            throw SSHCommandBuilderError.invalidUsername(context: context)
        }
    }

    private static func validatePort(_ port: Int, context: String) throws {
        guard (1 ... 65_535).contains(port) else {
            throw SSHCommandBuilderError.invalidPort(port: port, context: context)
        }
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.contains("\0") else {
            throw SSHCommandBuilderError.invalidPath(context: path)
        }
    }

    private static func proxyCommand(_ proxy: SSHProxy) throws -> String {
        let host: String
        let port: Int
        let mode: String
        let username: String?
        switch proxy {
        case let .http(proxyHost, proxyPort, proxyUsername):
            host = proxyHost
            port = proxyPort
            mode = "connect"
            username = proxyUsername
        case let .socks5(proxyHost, proxyPort, proxyUsername):
            host = proxyHost
            port = proxyPort
            mode = "5"
            username = proxyUsername
        }
        guard (1 ... 65_535).contains(port), isSafeProxyValue(host) else {
            throw SSHCommandBuilderError.unsupportedProxy
        }
        if let username, !isSafeProxyValue(username) {
            throw SSHCommandBuilderError.unsupportedProxy
        }
        let endpointHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var command = "/usr/bin/nc -X \(mode) -x \(shellQuote(endpointHost)):\(port)"
        if let username {
            command += " -P \(shellQuote(username))"
        }
        return command + " %h %p"
    }

    private static func isSafeProxyValue(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
            && !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func bracketsAreBalanced(_ host: String) -> Bool {
        host.hasPrefix("[") == host.hasSuffix("]")
    }

    private static func unbracketedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else {
            return host
        }
        return String(host.dropFirst().dropLast())
    }
}
