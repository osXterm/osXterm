import Foundation

/// A single host in an OpenSSH ProxyJump chain.
public struct SFTPJumpHost: Equatable, Sendable {
    public let host: String
    public let port: UInt16?
    public let username: String?

    public init(host: String, port: UInt16? = nil, username: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
    }
}

/// An OpenSSH option passed to `sftp` as one `-o name=value` argument.
///
/// Keeping the name and value separate prevents a caller from accidentally
/// turning an option value into extra command-line arguments.
public struct SFTPSSHOption: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A remote item returned by an SFTP directory listing.
public struct SFTPRemoteEntry: Hashable, Identifiable, Sendable {
    public let name: String
    public let isDirectory: Bool

    public var id: String { name }

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Connection information used by the system OpenSSH `sftp` executable.
///
/// Authentication helpers such as `SSH_AUTH_SOCK` and `SSH_ASKPASS` can be
/// supplied through `environment`. Existing process environment values are
/// retained and these values take precedence. Credentials themselves are never
/// placed in this configuration.
public struct SFTPConnectionConfiguration: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String?
    public let targetAlias: String?
    public let identityFileURL: URL?
    public let sshConfigFileURL: URL?
    public let proxy: SSHProxy?
    public let jumpHosts: [SFTPJumpHost]
    public let sshAgentSocketPath: String?
    public let sshOptions: [SFTPSSHOption]
    public let environment: [String: String]
    public let usesOpenSSHBatchMode: Bool

    public init(
        host: String,
        port: UInt16 = 22,
        username: String? = nil,
        targetAlias: String? = nil,
        identityFileURL: URL? = nil,
        sshConfigFileURL: URL? = nil,
        proxy: SSHProxy? = nil,
        jumpHosts: [SFTPJumpHost] = [],
        sshAgentSocketPath: String? = nil,
        sshOptions: [SFTPSSHOption] = [],
        environment: [String: String] = [:],
        usesOpenSSHBatchMode: Bool = true
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.targetAlias = targetAlias
        self.identityFileURL = identityFileURL
        self.sshConfigFileURL = sshConfigFileURL
        self.proxy = proxy
        self.jumpHosts = jumpHosts
        self.sshAgentSocketPath = sshAgentSocketPath
        self.sshOptions = sshOptions
        self.environment = environment
        self.usesOpenSSHBatchMode = usesOpenSSHBatchMode
    }
}

public extension SFTPConnectionConfiguration {
    /// Builds SFTP connection settings from the shared SSH profile model.
    ///
    /// Password profiles use a session-local AskPass helper. OpenSSH's `-b`
    /// mode disables interactive authentication, so password profiles feed the
    /// same command batch through standard input without `-b`.
    init(
        profile: SSHProfile,
        askPassPath: String? = nil,
        askPassSocketPath: String? = nil,
        sshConfigFileURL: URL? = nil,
        targetAlias: String? = nil,
        sshOptions: [SFTPSSHOption] = []
    ) throws {
        guard let target = SSHConnectionTarget.parse(
            host: profile.host,
            username: profile.username
        ) else {
            throw SFTPError.invalidConfiguration(
                "A host and username are required."
            )
        }

        guard let port = UInt16(exactly: profile.port), port != 0 else {
            throw SFTPError.invalidConfiguration("Profile port must be between 1 and 65535")
        }

        if sshConfigFileURL == nil, !profile.jumpHostProfileIDs.isEmpty {
            throw SFTPError.invalidConfiguration(
                "Jump Host profiles require a resolved SSH config"
            )
        }

        let jumpHosts = try profile.jumpHosts.map { jumpHost in
            guard let jumpPort = UInt16(exactly: jumpHost.port), jumpPort != 0 else {
                throw SFTPError.invalidConfiguration(
                    "Jump host port must be between 1 and 65535"
                )
            }
            return SFTPJumpHost(
                host: jumpHost.host,
                port: jumpPort,
                username: jumpHost.username
            )
        }

        var identityFileURL: URL?
        var sshAgentSocketPath: String?
        var environment: [String: String] = [:]
        var usesOpenSSHBatchMode = true

        switch profile.authentication {
        case let .agent(socketPath):
            sshAgentSocketPath = socketPath

        case let .identityFile(path):
            identityFileURL = URL(fileURLWithPath: path)

        case .password:
            guard let askPassPath, !askPassPath.isEmpty else {
                throw SFTPError.invalidConfiguration(
                    "A password profile requires an AskPass helper"
                )
            }
            guard let askPassSocketPath,
                  !askPassSocketPath.isEmpty,
                  !askPassSocketPath.contains("\0")
            else {
                throw SFTPError.invalidConfiguration(
                    "A password profile requires an active in-memory credential"
                )
            }
            environment["SSH_ASKPASS"] = askPassPath
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "osXterm"
            environment["OSXTERM_ASKPASS_SOCKET"] = askPassSocketPath
            usesOpenSSHBatchMode = false
        }

        self.init(
            host: target.host,
            port: port,
            username: target.username,
            targetAlias: targetAlias,
            identityFileURL: identityFileURL,
            sshConfigFileURL: sshConfigFileURL,
            proxy: profile.proxy,
            jumpHosts: jumpHosts,
            sshAgentSocketPath: sshAgentSocketPath,
            sshOptions: sshOptions,
            environment: environment,
            usesOpenSSHBatchMode: usesOpenSSHBatchMode
        )
    }
}

public struct SFTPProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(
        terminationStatus: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum SFTPError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidPath(String)
    case processLaunchFailed(String)
    case commandFailed(status: Int32, standardError: String)
    case invalidOutputEncoding
}

extension SFTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            "Invalid SFTP configuration: \(message)"
        case let .invalidPath(message):
            "Invalid SFTP path: \(message)"
        case let .processLaunchFailed(message):
            "Could not launch sftp: \(message)"
        case let .commandFailed(status, standardError):
            "sftp exited with status \(status): \(standardError)"
        case .invalidOutputEncoding:
            "sftp returned output that is not valid UTF-8"
        }
    }
}
