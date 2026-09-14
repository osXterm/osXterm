import Foundation

/// Parsed from the system OpenSSH version banner. The app checks this before
/// it emits features whose syntax would otherwise be ignored or fail only
/// after a user tries to connect.
public struct OpenSSHVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(parsing banner: String) throws {
        let pattern = #"OpenSSH_([0-9]+)\.([0-9]+)(?:p([0-9]+))?"#
        let range = NSRange(banner.startIndex..., in: banner)
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: banner,
            options: [],
            range: range
        ),
        let majorRange = Range(match.range(at: 1), in: banner),
        let minorRange = Range(match.range(at: 2), in: banner),
        let major = Int(banner[majorRange]),
        let minor = Int(banner[minorRange])
        else {
            throw OpenSSHRuntimeSupportError.unreadableVersion(banner)
        }
        let patch: Int
        if match.range(at: 3).location != NSNotFound,
           let patchRange = Range(match.range(at: 3), in: banner) {
            patch = Int(banner[patchRange]) ?? 0
        } else {
            patch = 0
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: OpenSSHVersion, rhs: OpenSSHVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum OpenSSHRuntimeSupportError: Error, Equatable, Sendable, LocalizedError {
    case executableUnavailable
    case invocationFailed(status: Int32, diagnostics: String)
    case unreadableVersion(String)
    case unsupportedProxyJump(required: OpenSSHVersion, found: OpenSSHVersion)
    case unsupportedRemoteDynamicForwarding(required: OpenSSHVersion, found: OpenSSHVersion)
    case unsupportedUnixSocketForwarding(required: OpenSSHVersion, found: OpenSSHVersion)
    case unsupportedSFTPSCP(required: OpenSSHVersion, found: OpenSSHVersion)

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "The system OpenSSH client at /usr/bin/ssh is unavailable."
        case let .invocationFailed(status, diagnostics):
            let clean = OpenSSHOutputSanitizer.displayMessage(diagnostics)
            return clean.isEmpty
                ? "The system OpenSSH capability check failed with status \(status)."
                : "The system OpenSSH capability check failed: \(clean)"
        case let .unreadableVersion(banner):
            return "Could not read the system OpenSSH version from \(OpenSSHOutputSanitizer.displayMessage(banner))."
        case let .unsupportedProxyJump(required, found):
            return "This system OpenSSH \(found.major).\(found.minor) does not support ProxyJump. Version \(required.major).\(required.minor) or later is required."
        case let .unsupportedRemoteDynamicForwarding(required, found):
            return "This system OpenSSH \(found.major).\(found.minor) does not support remote dynamic forwarding. Version \(required.major).\(required.minor) or later is required."
        case let .unsupportedUnixSocketForwarding(required, found):
            return "This system OpenSSH \(found.major).\(found.minor) does not support Unix socket forwarding. Version \(required.major).\(required.minor) or later is required."
        case let .unsupportedSFTPSCP(required, found):
            return "This system OpenSSH \(found.major).\(found.minor) does not support the required SFTP-backed SCP mode. Version \(required.major).\(required.minor) or later is required."
        }
    }
}

public struct OpenSSHCommandOutput: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol OpenSSHCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) throws -> OpenSSHCommandOutput
}

/// Used only for a bounded local capability check. Interactive SSH, tunnels,
/// and SFTP use their own managed process lifetimes.
public struct SystemOpenSSHCommandRunner: OpenSSHCommandRunning {
    public init() {}

    public func run(executableURL: URL, arguments: [String]) throws -> OpenSSHCommandOutput {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return OpenSSHCommandOutput(
            status: process.terminationStatus,
            standardOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            standardError: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

public struct OpenSSHCapabilities: Equatable, Sendable {
    public static let proxyJumpMinimum = OpenSSHVersion(major: 7, minor: 3)
    public static let unixSocketForwardingMinimum = OpenSSHVersion(major: 6, minor: 7)
    public static let remoteDynamicForwardingMinimum = OpenSSHVersion(major: 7, minor: 6)
    /// osXterm forces `scp -s`, which is available on the macOS 26 OpenSSH
    /// baseline. Version 9 also changed SCP's default transport to SFTP.
    public static let sftpBackedSCPMinimum = OpenSSHVersion(major: 9, minor: 0)

    public let version: OpenSSHVersion

    public init(version: OpenSSHVersion) {
        self.version = version
    }

    public static func current(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        runner: any OpenSSHCommandRunning = SystemOpenSSHCommandRunner()
    ) throws -> OpenSSHCapabilities {
        guard executableURL.path == "/usr/bin/ssh",
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw OpenSSHRuntimeSupportError.executableUnavailable
        }
        let result = try runner.run(executableURL: executableURL, arguments: ["-V"])
        let banner = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard result.status == 0 || banner.contains("OpenSSH_") else {
            throw OpenSSHRuntimeSupportError.invocationFailed(
                status: result.status,
                diagnostics: banner
            )
        }
        return OpenSSHCapabilities(version: try OpenSSHVersion(parsing: banner))
    }

    public func validate(route: ResolvedSSHRoute, forwardingRules: [ForwardingRule]) throws {
        if !route.hops.isEmpty, version < Self.proxyJumpMinimum {
            throw OpenSSHRuntimeSupportError.unsupportedProxyJump(
                required: Self.proxyJumpMinimum,
                found: version
            )
        }
        if forwardingRules.contains(where: { $0.enabled && $0.kind == .remoteDynamic }),
           version < Self.remoteDynamicForwardingMinimum {
            throw OpenSSHRuntimeSupportError.unsupportedRemoteDynamicForwarding(
                required: Self.remoteDynamicForwardingMinimum,
                found: version
            )
        }
        if forwardingRules.contains(where: {
            $0.enabled && ($0.kind == .localUnix || $0.kind == .remoteUnix)
        }), version < Self.unixSocketForwardingMinimum {
            throw OpenSSHRuntimeSupportError.unsupportedUnixSocketForwarding(
                required: Self.unixSocketForwardingMinimum,
                found: version
            )
        }
    }

    public func validateSFTPBackedSCP() throws {
        guard version >= Self.sftpBackedSCPMinimum else {
            throw OpenSSHRuntimeSupportError.unsupportedSFTPSCP(
                required: Self.sftpBackedSCPMinimum,
                found: version
            )
        }
    }
}

/// Parses evidence emitted by OpenSSH without persisting terminal output or
/// credentials. The service consumes these events to distinguish a live SSH
/// channel from a process that merely started.
public enum OpenSSHOutputEvent: Equatable, Sendable {
    case authenticated
    case authenticationFailed
    case hostKeyRejected
    case hostKeyChanged
    case transportFailure(String)
}

public enum OpenSSHOutputParser {
    public static func events(in text: String) -> [OpenSSHOutputEvent] {
        var results: [OpenSSHOutputEvent] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let lower = line.lowercased()
            if lower.contains("authenticated to ") || lower.contains("entering interactive session") {
                results.append(.authenticated)
            }
            if lower.contains("permission denied") || lower.contains("authentication failed") {
                results.append(.authenticationFailed)
            }
            if lower.contains("remote host identification has changed") {
                results.append(.hostKeyChanged)
            } else if lower.contains("host key verification failed") || lower.contains("no host key is known") {
                results.append(.hostKeyRejected)
            }
            if lower.contains("connection timed out")
                || lower.contains("connection refused")
                || lower.contains("could not resolve hostname")
                || lower.contains("network is unreachable")
                || lower.contains("operation timed out") {
                results.append(.transportFailure(OpenSSHOutputSanitizer.displayMessage(line)))
            }
        }
        return results
    }
}

/// Do not publish credentials or arbitrary terminal escape sequences in a
/// connection error. This intentionally keeps a short, printable diagnostic.
public enum OpenSSHOutputSanitizer {
    public static func displayMessage(_ value: String, limit: Int = 320) -> String {
        let printable = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        let collapsed = String(String.UnicodeScalarView(printable))
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(max(1, limit)))
    }
}
