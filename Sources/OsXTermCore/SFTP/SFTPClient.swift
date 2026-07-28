import Foundation

public struct SFTPClient: Sendable {
    public static let systemExecutableURL = URL(fileURLWithPath: "/usr/bin/sftp")

    private let configuration: SFTPConnectionConfiguration
    private let executableURL: URL
    private let processRunner: any SFTPProcessRunning

    public init(
        configuration: SFTPConnectionConfiguration,
        executableURL: URL = SFTPClient.systemExecutableURL,
        processRunner: any SFTPProcessRunning = SystemSFTPProcessRunner()
    ) {
        self.configuration = configuration
        self.executableURL = executableURL
        self.processRunner = processRunner
    }

    /// Returns the names printed by OpenSSH, preserving spaces.
    public func list(remotePath: String) async throws -> [String] {
        try await listEntries(remotePath: remotePath).map(\.name)
    }

    /// Returns visible remote entries with their file type.
    ///
    /// The batch command uses long format so the first permission character
    /// identifies directories. Dot files are filtered here as a core
    /// invariant, rather than relying only on the SwiftUI presentation.
    public func listEntries(remotePath: String) async throws -> [SFTPRemoteEntry] {
        let result = try await execute(batch: SFTPBatchEncoder.list(remotePath))
        guard let output = String(data: result.standardOutput, encoding: .utf8) else {
            throw SFTPError.invalidOutputEncoding
        }

        return output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { line in
                line.hasSuffix("\r") ? String(line.dropLast()) : line
            }
            .compactMap { Self.listingEntry(from: $0, in: remotePath) }
            .filter { !$0.name.hasPrefix(".") }
    }

    public func upload(localURL: URL, to remotePath: String) async throws {
        _ = try await execute(
            batch: SFTPBatchEncoder.upload(localURL: localURL, remotePath: remotePath)
        )
    }

    public func download(remotePath: String, to localURL: URL) async throws {
        _ = try await execute(
            batch: SFTPBatchEncoder.download(remotePath: remotePath, localURL: localURL)
        )
    }

    public func makeDirectory(remotePath: String) async throws {
        _ = try await execute(batch: SFTPBatchEncoder.makeDirectory(remotePath))
    }

    public func rename(remotePath: String, to destinationPath: String) async throws {
        _ = try await execute(
            batch: SFTPBatchEncoder.rename(from: remotePath, to: destinationPath)
        )
    }

    public func remove(remotePath: String) async throws {
        _ = try await execute(batch: SFTPBatchEncoder.remove(remotePath))
    }

    private func execute(batch: Data) async throws -> SFTPProcessResult {
        let invocation = try makeInvocation()
        let result = try await processRunner.run(
            executableURL: executableURL,
            arguments: invocation.arguments,
            standardInput: batch,
            environment: invocation.environment
        )

        guard result.terminationStatus == 0 else {
            let standardError = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SFTPError.commandFailed(
                status: result.terminationStatus,
                standardError: standardError
            )
        }
        return result
    }

    private func makeInvocation() throws -> (arguments: [String], environment: [String: String]) {
        guard configuration.port != 0 else {
            throw SFTPError.invalidConfiguration("Port must be between 1 and 65535")
        }

        let destination = try Self.destination(
            host: configuration.host,
            username: configuration.username
        )

        var arguments = ["-q"]
        let hasAskPassHelper = configuration.environment["SSH_ASKPASS"]?.isEmpty == false
        if configuration.usesOpenSSHBatchMode && !hasAskPassHelper {
            arguments += ["-b", "-"]
        }
        if configuration.targetAlias == nil {
            arguments += ["-P", String(configuration.port)]
        }

        if let sshConfigFileURL = configuration.sshConfigFileURL {
            guard sshConfigFileURL.isFileURL else {
                throw SFTPError.invalidConfiguration("SSH config must be a file URL")
            }
            arguments += ["-F", sshConfigFileURL.path]
        }

        if let identityFileURL = configuration.identityFileURL,
           configuration.targetAlias == nil
        {
            guard identityFileURL.isFileURL else {
                throw SFTPError.invalidConfiguration("Identity file must be a file URL")
            }
            arguments += ["-i", identityFileURL.path]
        }

        if configuration.targetAlias == nil, !configuration.jumpHosts.isEmpty {
            let jumpChain = try configuration.jumpHosts
                .map(Self.jumpDestination)
                .joined(separator: ",")
            arguments += ["-J", jumpChain]
        }

        if configuration.targetAlias == nil, let proxy = configuration.proxy {
            arguments += ["-o", "ProxyCommand=\(try Self.proxyCommand(proxy))"]
        }

        for option in configuration.sshOptions {
            try Self.validateOption(option)
            arguments += ["-o", "\(option.name)=\(option.value)"]
        }

        arguments.append(configuration.targetAlias ?? destination)

        var environment = configuration.environment
        if let sshAgentSocketPath = configuration.sshAgentSocketPath {
            guard !sshAgentSocketPath.isEmpty,
                  !Self.containsLineControl(sshAgentSocketPath)
            else {
                throw SFTPError.invalidConfiguration("SSH agent socket path is invalid")
            }
            environment["SSH_AUTH_SOCK"] = sshAgentSocketPath
        }

        return (arguments, environment)
    }

    private static func destination(host: String, username: String?) throws -> String {
        let validatedHost = try validateHost(host)
        let hostComponent = validatedHost.contains(":") ? "[\(validatedHost)]" : validatedHost

        guard let username else {
            return hostComponent
        }
        try validateUsername(username)
        return "\(username)@\(hostComponent)"
    }

    private static func listingEntry(
        from line: String,
        in remotePath: String
    ) -> SFTPRemoteEntry? {
        guard !line.isEmpty, !line.hasPrefix("sftp> ") else {
            return nil
        }

        let isLongListing = line.first.map {
            "-dlcbps".contains($0)
        } == true

        let rawEntry: String
        if isLongListing {
            // Split only the first eight fields. The ninth field is the
            // original filename and may itself contain spaces.
            let fields = line.split(
                maxSplits: 8,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count >= 9 else {
                return nil
            }
            rawEntry = String(fields[8])
        } else {
            rawEntry = line
        }

        let directoryPrefix: String
        if remotePath == "/" {
            directoryPrefix = "/"
        } else {
            directoryPrefix = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        }

        let entry: String
        if rawEntry.hasPrefix(directoryPrefix) {
            entry = String(rawEntry.dropFirst(directoryPrefix.count))
        } else {
            entry = rawEntry
        }

        guard !entry.isEmpty else {
            return nil
        }
        return SFTPRemoteEntry(
            name: entry,
            isDirectory: line.first == "d"
        )
    }

    private static func jumpDestination(_ jumpHost: SFTPJumpHost) throws -> String {
        let validatedHost = try validateHost(jumpHost.host, disallowed: [","])
        let hostComponent = validatedHost.contains(":") ? "[\(validatedHost)]" : validatedHost
        var destination = hostComponent

        if let username = jumpHost.username {
            try validateUsername(username, disallowed: [","])
            destination = "\(username)@\(destination)"
        }
        if let port = jumpHost.port {
            guard port != 0 else {
                throw SFTPError.invalidConfiguration(
                    "Jump host port must be between 1 and 65535"
                )
            }
            destination += ":\(port)"
        }
        return destination
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
            throw SFTPError.invalidConfiguration("Proxy is invalid")
        }
        if let username, !isSafeProxyValue(username) {
            throw SFTPError.invalidConfiguration("Proxy username is invalid")
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

    private static func validateHost(
        _ host: String,
        disallowed additionalDisallowedCharacters: Set<Character> = []
    ) throws -> String {
        let unwrappedHost: String
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            unwrappedHost = String(host.dropFirst().dropLast())
        } else {
            unwrappedHost = host
        }

        guard !unwrappedHost.isEmpty,
              unwrappedHost.first != "-",
              !containsEndpointControl(unwrappedHost),
              !unwrappedHost.contains("@"),
              !unwrappedHost.contains(","),
              !unwrappedHost.contains(where: additionalDisallowedCharacters.contains)
        else {
            throw SFTPError.invalidConfiguration("Host is invalid")
        }
        return unwrappedHost
    }

    private static func validateUsername(
        _ username: String,
        disallowed additionalDisallowedCharacters: Set<Character> = []
    ) throws {
        guard !username.isEmpty,
              username.first != "-",
              !containsEndpointControl(username),
              !username.contains(","),
              !username.contains("/"),
              !username.contains(where: additionalDisallowedCharacters.contains)
        else {
            throw SFTPError.invalidConfiguration("Username is invalid")
        }
    }

    private static func validateOption(_ option: SFTPSSHOption) throws {
        guard !option.name.isEmpty,
              option.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              !option.value.isEmpty,
              !containsLineControl(option.value)
        else {
            throw SFTPError.invalidConfiguration("SSH option is invalid")
        }
    }

    private static func containsLineControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.value == 0 || $0.value == 10 || $0.value == 13
        }
    }

    private static func containsEndpointControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
        }
    }
}
