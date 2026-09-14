import Foundation

/// A shell-free launch description for the system OpenSSH client.
public struct OpenSSHInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environmentOverrides: [String: String]
    public let purpose: OpenSSHCommandPurpose
    public let credentialRequirements: [OpenSSHCredentialRequirement]

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        purpose: OpenSSHCommandPurpose,
        credentialRequirements: [OpenSSHCredentialRequirement] = []
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
        self.purpose = purpose
        self.credentialRequirements = credentialRequirements
    }

    public var requiresAskPass: Bool {
        credentialRequirements.contains {
            if case .askPass = $0 { return true }
            return false
        }
    }
}

public enum OpenSSHCommandPurpose: Equatable, Sendable {
    case interactive
    case tunnel
    case subsystem(String)
    /// A file-copy invocation uses the same generated route configuration as
    /// a terminal or SFTP subsystem, but is executed by `/usr/bin/scp`.
    case fileTransfer
}

public enum OpenSSHCredentialRequirement: Equatable, Sendable {
    case askPass(secret: SecretReference, profileID: UUID)
    case proxy(secret: SecretReference, prompt: String)
}

public enum OpenSSHCommandCompilerError: Error, Equatable, Sendable {
    case invalidExecutable
    case invalidSCPExecutable
    case invalidHost(UUID)
    case invalidUsername(UUID)
    case invalidPort(profileID: UUID, port: Int)
    case invalidAuthenticationPath(UUID)
    case invalidCertificatePath(UUID)
    case invalidOptions(UUID)
    case invalidKnownHostsPath
    case invalidSubsystem(String)
    case configurationDoesNotMatchRoute
    case proxyHelperRequired
    case proxyCredentialBrokerRequired
    case noEnabledForwardings
    case invalidForwarding(ruleID: UUID, reason: String)
}

extension OpenSSHCommandCompilerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidExecutable:
            "The system OpenSSH executable is unavailable."
        case .invalidSCPExecutable:
            "The system SCP executable is unavailable."
        case let .invalidHost(id):
            "Profile \(id.uuidString) has an invalid host."
        case let .invalidUsername(id):
            "Profile \(id.uuidString) has an invalid username."
        case let .invalidPort(profileID, port):
            "Profile \(profileID.uuidString) has invalid port \(port)."
        case let .invalidAuthenticationPath(id):
            "Profile \(id.uuidString) has an invalid identity or agent path."
        case let .invalidCertificatePath(id):
            "Profile \(id.uuidString) has an invalid OpenSSH certificate path."
        case let .invalidOptions(id):
            "Profile \(id.uuidString) has invalid SSH options."
        case .invalidKnownHostsPath:
            "The app-managed known_hosts location is invalid."
        case let .invalidSubsystem(name):
            "SSH subsystem \(name) is invalid."
        case .configurationDoesNotMatchRoute:
            "The generated SSH configuration belongs to another route."
        case .proxyHelperRequired:
            "This route requires the packaged proxy helper."
        case .proxyCredentialBrokerRequired:
            "Authenticated proxy access requires a session credential broker."
        case .noEnabledForwardings:
            "No enabled forwarding rules were supplied for the tunnel."
        case let .invalidForwarding(ruleID, reason):
            "Forwarding rule \(ruleID.uuidString) is invalid: \(reason)"
        }
    }
}

/// Owns one mode-0700 temporary configuration directory. Keep this instance
/// alive for as long as OpenSSH, SFTP, or an independent tunnel uses it.
public final class OpenSSHRouteConfiguration: @unchecked Sendable {
    public let directoryURL: URL
    public let fileURL: URL
    public let knownHostsURL: URL
    public let targetAlias: String
    public let profileIDs: [UUID]

    public init(
        route: ResolvedSSHRoute,
        knownHostsURL: URL,
        proxyHelper: ProxyHelperLaunchConfiguration? = nil,
        hostKeyPolicy: OpenSSHHostKeyPolicy = .requireKnown,
        baseDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true),
        sessionID: UUID = UUID()
    ) throws {
        try OpenSSHCommandCompiler.validate(route: route)
        guard knownHostsURL.isFileURL,
              knownHostsURL.path.hasPrefix("/"),
              SSHInputValidator.localPath(knownHostsURL.path)
        else {
            throw OpenSSHCommandCompilerError.invalidKnownHostsPath
        }

        let proxy = try route.localTransportProxy()
        if proxy != nil, proxyHelper == nil {
            throw OpenSSHCommandCompilerError.proxyHelperRequired
        }

        let directoryURL = baseDirectory.appendingPathComponent(
            "osxterm-route-\(sessionID.uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let fileURL = directoryURL.appendingPathComponent("ssh_config", isDirectory: false)

        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.knownHostsURL = knownHostsURL
        self.targetAlias = Self.alias(for: route.target)
        self.profileIDs = route.profiles.map(\.id)

        do {
            try Self.ensureKnownHostsFile(at: knownHostsURL)
            let text = try Self.makeConfig(
                route: route,
                knownHostsURL: knownHostsURL,
                proxy: proxy,
                proxyHelper: proxyHelper,
                hostKeyPolicy: hostKeyPolicy
            )
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    deinit {
        cleanup()
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    public static func alias(for profile: ConnectionProfile) -> String {
        "osxterm-\(profile.id.uuidString.lowercased())"
    }

    private static func ensureKnownHostsFile(at url: URL) throws {
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: parent.path) {
            try manager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !manager.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func makeConfig(
        route: ResolvedSSHRoute,
        knownHostsURL: URL,
        proxy: ProxyConfiguration?,
        proxyHelper: ProxyHelperLaunchConfiguration?,
        hostKeyPolicy: OpenSSHHostKeyPolicy
    ) throws -> String {
        guard let knownHostsValue = SSHInputValidator.configValue(knownHostsURL.path) else {
            throw OpenSSHCommandCompilerError.invalidKnownHostsPath
        }
        var lines = [
            "# Generated by osXterm for one session. Do not edit.",
            "Host *",
            "    UserKnownHostsFile \(knownHostsValue)",
            "    GlobalKnownHostsFile /dev/null",
            "    StrictHostKeyChecking \(hostKeyPolicy.openSSHValue)",
            "    UpdateHostKeys no",
            "    HashKnownHosts no",
            "    ControlMaster no",
            ""
        ]

        let hopAliases = route.hops.map(alias(for:))
        let outermostID = route.outermostProfile.id
        for profile in route.profiles {
            let alias = alias(for: profile)
            let endpoint = try SSHHostKeyEndpoint(host: profile.host, port: profile.port)
            guard let host = SSHInputValidator.configValue(SSHInputValidator.unbracketedIPv6(profile.host)),
                  let username = SSHInputValidator.configValue(profile.username),
                  let hostKeyAlias = SSHInputValidator.configValue(endpoint.knownHostsToken)
            else {
                throw OpenSSHCommandCompilerError.invalidHost(profile.id)
            }

            lines.append("Host \(alias)")
            lines.append("    HostName \(host)")
            lines.append("    User \(username)")
            lines.append("    Port \(profile.port)")
            lines.append("    HostKeyAlias \(hostKeyAlias)")
            lines.append("    ConnectTimeout \(Int(profile.options.connectTimeout))")
            lines.append("    ServerAliveInterval \(Int(profile.options.serverAliveInterval))")
            lines.append("    ServerAliveCountMax \(profile.options.serverAliveCountMax)")
            lines.append("    ForwardAgent \(profile.options.forwardAgent ? "yes" : "no")")
            lines.append(contentsOf: try authenticationLines(for: profile))

            if let certificatePath = profile.certificatePath {
                guard let value = SSHInputValidator.configValue(certificatePath) else {
                    throw OpenSSHCommandCompilerError.invalidCertificatePath(profile.id)
                }
                lines.append("    CertificateFile \(value)")
            }

            if profile.id == outermostID, let proxy {
                guard let proxyHelper else {
                    throw OpenSSHCommandCompilerError.proxyHelperRequired
                }
                let renderedProxyCommand = try proxyCommand(
                    proxy: proxy,
                    helper: proxyHelper
                )
                lines.append("    ProxyCommand \(renderedProxyCommand)")
            }

            if profile.id == route.target.id, !hopAliases.isEmpty {
                guard let proxyJump = SSHInputValidator.configValue(hopAliases.joined(separator: ",")) else {
                    throw OpenSSHCommandCompilerError.configurationDoesNotMatchRoute
                }
                lines.append("    ProxyJump \(proxyJump)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func authenticationLines(for profile: ConnectionProfile) throws -> [String] {
        switch profile.authentication {
        case let .agent(socketPath):
            var lines = [
                "    PreferredAuthentications publickey",
                "    PasswordAuthentication no",
                "    KbdInteractiveAuthentication no"
            ]
            if let socketPath {
                guard SSHInputValidator.localPath(socketPath),
                      let value = SSHInputValidator.configValue(socketPath)
                else {
                    throw OpenSSHCommandCompilerError.invalidAuthenticationPath(profile.id)
                }
                lines.append("    IdentityAgent \(value)")
            }
            return lines

        case let .privateKey(path, _):
            guard SSHInputValidator.localPath(path),
                  let value = SSHInputValidator.configValue(path)
            else {
                throw OpenSSHCommandCompilerError.invalidAuthenticationPath(profile.id)
            }
            return [
                "    IdentityFile \(value)",
                "    IdentitiesOnly yes",
                "    PreferredAuthentications publickey",
                "    PasswordAuthentication no",
                "    KbdInteractiveAuthentication no"
            ]

        case .password:
            return [
                "    PreferredAuthentications keyboard-interactive,password",
                "    PubkeyAuthentication no",
                "    NumberOfPasswordPrompts 1"
            ]

        case .keyboardInteractive:
            return [
                "    PreferredAuthentications keyboard-interactive",
                "    PasswordAuthentication no",
                "    NumberOfPasswordPrompts 1"
            ]
        }
    }

    private static func proxyCommand(
        proxy: ProxyConfiguration,
        helper: ProxyHelperLaunchConfiguration
    ) throws -> String {
        try ProxyHelperDescriptor(sessionID: helper.sessionID, proxy: proxy).validate()
        guard helper.executableURL.isFileURL,
              helper.executableURL.path.hasPrefix("/"),
              !helper.executableURL.path.contains("\0"),
              !helper.executableURL.path.unicodeScalars.contains(where: {
                  CharacterSet.newlines.union(.controlCharacters).contains($0)
              })
        else {
            throw OpenSSHCommandCompilerError.proxyHelperRequired
        }

        var arguments = [
            helper.executableURL.path,
            "--kind", proxy.kind == .httpConnect ? "http-connect" : "socks5",
            "--host", proxy.host,
            "--port", String(proxy.port),
            "--target-host", "%h",
            "--target-port", "%p"
        ]
        if let username = proxy.username {
            guard let socketPath = helper.socketPath,
                  let token = helper.token,
                  SessionCredentialBroker.isSafeSocketPath(socketPath),
                  !token.isEmpty,
                  !token.contains("\0")
            else {
                throw OpenSSHCommandCompilerError.proxyCredentialBrokerRequired
            }
            arguments.append(contentsOf: [
                "--credential-socket", socketPath,
                "--credential-token", token,
                "--username", username
            ])
        }
        return arguments.map(SSHInputValidator.shellQuote).joined(separator: " ")
    }
}

/// Bundles the invocation and configuration so callers cannot accidentally
/// release the short-lived config before the process exits.
public final class PreparedOpenSSHCommand: @unchecked Sendable {
    public let invocation: OpenSSHInvocation
    public let configuration: OpenSSHRouteConfiguration

    public init(invocation: OpenSSHInvocation, configuration: OpenSSHRouteConfiguration) {
        self.invocation = invocation
        self.configuration = configuration
    }
}

public struct OpenSSHCommandCompiler: Sendable {
    public let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.executableURL = executableURL
    }

    public func prepare(
        route: ResolvedSSHRoute,
        knownHostsURL: URL,
        proxyHelper: ProxyHelperLaunchConfiguration? = nil,
        hostKeyPolicy: OpenSSHHostKeyPolicy = .requireKnown,
        purpose: OpenSSHCommandPurpose = .interactive,
        forwardingRules: [ForwardingRule]? = nil,
        baseDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    ) throws -> PreparedOpenSSHCommand {
        let configuration = try OpenSSHRouteConfiguration(
            route: route,
            knownHostsURL: knownHostsURL,
            proxyHelper: proxyHelper,
            hostKeyPolicy: hostKeyPolicy,
            baseDirectory: baseDirectory
        )
        do {
            let invocation = try compile(
                route: route,
                configuration: configuration,
                purpose: purpose,
                forwardingRules: forwardingRules
            )
            return PreparedOpenSSHCommand(invocation: invocation, configuration: configuration)
        } catch {
            configuration.cleanup()
            throw error
        }
    }

    public func compile(
        route: ResolvedSSHRoute,
        configuration: OpenSSHRouteConfiguration,
        purpose: OpenSSHCommandPurpose = .interactive,
        forwardingRules: [ForwardingRule]? = nil
    ) throws -> OpenSSHInvocation {
        guard executableURL.isFileURL, executableURL.path == "/usr/bin/ssh" else {
            throw OpenSSHCommandCompilerError.invalidExecutable
        }
        try Self.validate(route: route)
        guard configuration.targetAlias == OpenSSHRouteConfiguration.alias(for: route.target),
              configuration.profileIDs == route.profiles.map(\.id)
        else {
            throw OpenSSHCommandCompilerError.configurationDoesNotMatchRoute
        }

        let selectedRules = (forwardingRules ?? route.target.forwardingRules).filter(\.enabled)
        var arguments = ["-F", configuration.fileURL.path, "-o", "BatchMode=no"]

        switch purpose {
        case .interactive:
            arguments.append(contentsOf: [
                route.target.options.requestTTY ? "-tt" : "-T",
                "-o", "LogLevel=VERBOSE"
            ])
        case .tunnel:
            guard !selectedRules.isEmpty else {
                throw OpenSSHCommandCompilerError.noEnabledForwardings
            }
            arguments.append(contentsOf: ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "LogLevel=VERBOSE"])
        case let .subsystem(name):
            guard Self.isSafeSubsystem(name) else {
                throw OpenSSHCommandCompilerError.invalidSubsystem(name)
            }
            arguments.append(contentsOf: ["-T", "-s", name])
        case .fileTransfer:
            // `fileTransfer` is produced by `prepareSCP`, which uses the
            // same route configuration but a separate `/usr/bin/scp` argv.
            throw OpenSSHCommandCompilerError.invalidSCPExecutable
        }

        for rule in selectedRules {
            let rendered = try Self.render(rule: rule)
            arguments.append(contentsOf: [rendered.option, rendered.value])
        }
        arguments.append(configuration.targetAlias)

        return OpenSSHInvocation(
            executableURL: executableURL,
            arguments: arguments,
            purpose: purpose,
            credentialRequirements: try Self.credentialRequirements(for: route)
        )
    }

    /// Prepares a shell-free `/usr/bin/scp` invocation while retaining the
    /// generated route configuration for the process lifetime. The caller
    /// appends local and remote operands as individual argument-array items.
    /// This means a profile, jump chain, proxy and authentication policy are
    /// shared with terminal and SFTP launches rather than reassembled by UI.
    public func prepareSCP(
        route: ResolvedSSHRoute,
        knownHostsURL: URL,
        proxyHelper: ProxyHelperLaunchConfiguration? = nil,
        hostKeyPolicy: OpenSSHHostKeyPolicy = .requireKnown,
        baseDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true),
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/scp")
    ) throws -> PreparedOpenSSHCommand {
        guard executableURL.isFileURL,
              executableURL.path == "/usr/bin/scp"
        else {
            throw OpenSSHCommandCompilerError.invalidSCPExecutable
        }

        let configuration = try OpenSSHRouteConfiguration(
            route: route,
            knownHostsURL: knownHostsURL,
            proxyHelper: proxyHelper,
            hostKeyPolicy: hostKeyPolicy,
            baseDirectory: baseDirectory
        )
        do {
            try Self.validate(route: route)
            guard configuration.targetAlias == OpenSSHRouteConfiguration.alias(for: route.target),
                  configuration.profileIDs == route.profiles.map(\.id)
            else {
                throw OpenSSHCommandCompilerError.configurationDoesNotMatchRoute
            }
            let invocation = OpenSSHInvocation(
                executableURL: executableURL,
                arguments: [
                    "-F", configuration.fileURL.path,
                    "-o", "BatchMode=no",
                    "-o", "LogLevel=VERBOSE"
                ],
                purpose: .fileTransfer,
                credentialRequirements: try Self.credentialRequirements(for: route)
            )
            return PreparedOpenSSHCommand(invocation: invocation, configuration: configuration)
        } catch {
            configuration.cleanup()
            throw error
        }
    }

    static func validate(route: ResolvedSSHRoute) throws {
        _ = try route.localTransportProxy()
        for profile in route.profiles {
            guard SSHInputValidator.host(profile.host) else {
                throw OpenSSHCommandCompilerError.invalidHost(profile.id)
            }
            guard SSHInputValidator.username(profile.username) else {
                throw OpenSSHCommandCompilerError.invalidUsername(profile.id)
            }
            guard SSHInputValidator.port(profile.port) else {
                throw OpenSSHCommandCompilerError.invalidPort(profileID: profile.id, port: profile.port)
            }
            guard profile.options.connectTimeout.isFinite,
                  profile.options.connectTimeout > 0,
                  profile.options.connectTimeout.rounded(.towardZero) == profile.options.connectTimeout,
                  profile.options.serverAliveInterval.isFinite,
                  profile.options.serverAliveInterval >= 0,
                  profile.options.serverAliveInterval.rounded(.towardZero) == profile.options.serverAliveInterval,
                  profile.options.serverAliveCountMax >= 0,
                  profile.options.maximumReconnectAttempts >= 0
            else {
                throw OpenSSHCommandCompilerError.invalidOptions(profile.id)
            }

            switch profile.authentication {
            case let .agent(socketPath):
                if let socketPath, !SSHInputValidator.localPath(socketPath) {
                    throw OpenSSHCommandCompilerError.invalidAuthenticationPath(profile.id)
                }
            case let .privateKey(path, _):
                guard SSHInputValidator.localPath(path) else {
                    throw OpenSSHCommandCompilerError.invalidAuthenticationPath(profile.id)
                }
            case .password, .keyboardInteractive:
                break
            }
            if let certificatePath = profile.certificatePath,
               !SSHInputValidator.localPath(certificatePath) {
                throw OpenSSHCommandCompilerError.invalidCertificatePath(profile.id)
            }
        }
    }

    private static func credentialRequirements(
        for route: ResolvedSSHRoute
    ) throws -> [OpenSSHCredentialRequirement] {
        var requirements: [OpenSSHCredentialRequirement] = []
        for profile in route.profiles {
            switch profile.authentication {
            case let .privateKey(_, passphrase):
                if let passphrase {
                    requirements.append(.askPass(secret: passphrase, profileID: profile.id))
                }
            case let .password(secret):
                requirements.append(.askPass(secret: secret, profileID: profile.id))
            case let .keyboardInteractive(secret):
                if let secret {
                    requirements.append(.askPass(secret: secret, profileID: profile.id))
                }
            case .agent:
                break
            }
        }
        if let proxy = try route.localTransportProxy(), let secret = proxy.password, let username = proxy.username {
            requirements.append(.proxy(
                secret: secret,
                prompt: ProxyCredentialPrompt.make(username: username, host: proxy.host, port: proxy.port)
            ))
        }
        return requirements
    }

    private static func isSafeSubsystem(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }

    private static func render(rule: ForwardingRule) throws -> (option: String, value: String) {
        switch rule.kind {
        case .local:
            return ("-L", try tcpForwardingValue(rule: rule, remote: false))
        case .remote:
            return ("-R", try tcpForwardingValue(rule: rule, remote: true))
        case .dynamic:
            return ("-D", try dynamicForwardingValue(rule: rule, remote: false))
        case .remoteDynamic:
            return ("-R", try dynamicForwardingValue(rule: rule, remote: true))
        case .localUnix:
            return ("-L", try unixForwardingValue(rule: rule))
        case .remoteUnix:
            return ("-R", try unixForwardingValue(rule: rule))
        }
    }

    private static func tcpForwardingValue(rule: ForwardingRule, remote: Bool) throws -> String {
        let listener = try listenerAddress(rule: rule, allowsZero: remote)
        let destination = try destinationValue(rule: rule)
        return "\(listener):\(destination)"
    }

    private static func dynamicForwardingValue(rule: ForwardingRule, remote: Bool) throws -> String {
        try listenerAddress(rule: rule, allowsZero: remote)
    }

    private static func unixForwardingValue(rule: ForwardingRule) throws -> String {
        guard let listenPath = rule.listenPath, SSHInputValidator.socketPath(listenPath) else {
            throw OpenSSHCommandCompilerError.invalidForwarding(ruleID: rule.id, reason: "a safe Unix socket listener path is required")
        }
        if let destinationPath = rule.destinationPath, !destinationPath.isEmpty {
            guard SSHInputValidator.socketPath(destinationPath) else {
                throw OpenSSHCommandCompilerError.invalidForwarding(ruleID: rule.id, reason: "the Unix socket destination path is invalid")
            }
            return "\(listenPath):\(destinationPath)"
        }
        return "\(listenPath):\(try destinationValue(rule: rule))"
    }

    private static func listenerAddress(rule: ForwardingRule, allowsZero: Bool) throws -> String {
        guard let port = rule.listenPort, SSHInputValidator.port(port, allowsZero: allowsZero) else {
            throw OpenSSHCommandCompilerError.invalidForwarding(ruleID: rule.id, reason: "the listener port is invalid")
        }
        let rawAddress = rule.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let bindAddress = rawAddress.isEmpty ? "127.0.0.1" : rawAddress
        guard isSafeBindAddress(bindAddress) else {
            throw OpenSSHCommandCompilerError.invalidForwarding(ruleID: rule.id, reason: "the bind address is invalid")
        }
        guard rule.exposeExternally || SSHInputValidator.isLoopback(bindAddress) else {
            throw OpenSSHCommandCompilerError.invalidForwarding(ruleID: rule.id, reason: "external binding requires explicit opt-in")
        }
        return "\(SSHInputValidator.bracketedIfNeeded(bindAddress)):\(port)"
    }

    private static func destinationValue(rule: ForwardingRule) throws -> String {
        guard let host = rule.destinationHost, SSHInputValidator.host(host) else {
            throw OpenSSHCommandCompilerError.invalidForwarding(ruleID: rule.id, reason: "the destination host is invalid")
        }
        guard let port = rule.destinationPort, SSHInputValidator.port(port) else {
            throw OpenSSHCommandCompilerError.invalidForwarding(ruleID: rule.id, reason: "the destination port is invalid")
        }
        return "\(SSHInputValidator.bracketedIfNeeded(host)):\(port)"
    }

    private static func isSafeBindAddress(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("\0")
            && !value.contains("@")
            && !value.contains(",")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }
}
