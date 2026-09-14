import CryptoKit
import Foundation

public enum SSHHostKeyEndpointError: Error, Equatable, Sendable {
    case invalidHost
    case invalidPort(Int)
}

/// The canonical form used both by the app-managed known_hosts file and the
/// generated `HostKeyAlias` setting. A non-default port uses OpenSSH's
/// bracketed known_hosts syntax.
public struct SSHHostKeyEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int = 22) throws {
        guard SSHInputValidator.host(host) else {
            throw SSHHostKeyEndpointError.invalidHost
        }
        guard SSHInputValidator.port(port) else {
            throw SSHHostKeyEndpointError.invalidPort(port)
        }
        self.host = SSHInputValidator.unbracketedIPv6(host).lowercased()
        self.port = port
    }

    public var knownHostsToken: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}

public enum SSHHostKeyError: Error, Equatable, Sendable {
    case invalidAlgorithm
    case invalidBase64
}

public struct SSHHostKey: Codable, Hashable, Sendable {
    public let algorithm: String
    public let base64EncodedKey: String

    public init(algorithm: String, base64EncodedKey: String) throws {
        guard !algorithm.isEmpty,
              !algorithm.hasPrefix("-"),
              !algorithm.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              })
        else {
            throw SSHHostKeyError.invalidAlgorithm
        }
        guard let decoded = Data(base64Encoded: base64EncodedKey), !decoded.isEmpty else {
            throw SSHHostKeyError.invalidBase64
        }
        self.algorithm = algorithm
        self.base64EncodedKey = base64EncodedKey
    }

    public var sha256Fingerprint: String {
        let keyData = Data(base64Encoded: base64EncodedKey) ?? Data()
        let digest = SHA256.hash(data: keyData)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

public struct SSHKnownHostRecord: Codable, Hashable, Sendable {
    public let endpoint: SSHHostKeyEndpoint
    public let key: SSHHostKey
    public let addedAt: Date

    public init(endpoint: SSHHostKeyEndpoint, key: SSHHostKey, addedAt: Date = .now) {
        self.endpoint = endpoint
        self.key = key
        self.addedAt = addedAt
    }
}

public enum HostKeyVerification: Equatable, Sendable {
    case unknown(presentedFingerprint: String)
    case trusted(fingerprint: String)
    case changed(presentedFingerprint: String, trustedFingerprints: [String])
}

public enum HostKeyApproval: Equatable, Sendable {
    case trustNew
    case replaceChanged
}

/// `acceptNewAfterUserConfirmation` is valid only after the app first showed
/// the blocked connection's fingerprint and the user approved it. OpenSSH
/// still rejects changed keys under this policy.
public enum OpenSSHHostKeyPolicy: Equatable, Sendable {
    case requireKnown
    /// Uses OpenSSH's interactive confirmation prompt. The app routes that
    /// prompt over its per-session AskPass IPC and does not answer it until
    /// the user has seen the presented fingerprint.
    case promptUser
    case acceptNewAfterUserConfirmation

    var openSSHValue: String {
        switch self {
        case .requireKnown: "yes"
        case .promptUser: "ask"
        case .acceptNewAfterUserConfirmation: "accept-new"
        }
    }
}

public enum HostKeyStoreError: Error, Equatable, Sendable {
    case changedKeyRequiresExplicitReplacement(HostKeyVerification)
    case invalidKnownHostsLine(Int)
    case invalidFileURL
}

extension HostKeyStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .changedKeyRequiresExplicitReplacement:
            "The server host key changed and needs explicit replacement approval."
        case let .invalidKnownHostsLine(line):
            "The app-managed known_hosts file has an invalid entry on line \(line)."
        case .invalidFileURL:
            "The app-managed known_hosts file location is invalid."
        }
    }
}

/// Stores only user-approved keys in an app-managed known_hosts file. Unknown
/// and changed keys remain blocked until the caller records an explicit
/// approval; no key is learned automatically.
public actor HostKeyStore {
    public nonisolated let fileURL: URL
    private var records: [SSHKnownHostRecord]

    public init(fileURL: URL) throws {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else {
            throw HostKeyStoreError.invalidFileURL
        }
        self.fileURL = fileURL
        self.records = try Self.loadRecords(from: fileURL)
    }

    public func allRecords() -> [SSHKnownHostRecord] {
        records.sorted {
            if $0.endpoint.knownHostsToken != $1.endpoint.knownHostsToken {
                return $0.endpoint.knownHostsToken < $1.endpoint.knownHostsToken
            }
            return $0.key.algorithm < $1.key.algorithm
        }
    }

    /// Reload after an explicitly user-approved OpenSSH `accept-new` run.
    /// The client writes the standard known_hosts format, which is then used
    /// by the next strict connection attempt.
    public func reload() throws {
        records = try Self.loadRecords(from: fileURL)
    }

    public func verification(
        endpoint: SSHHostKeyEndpoint,
        presented: SSHHostKey
    ) -> HostKeyVerification {
        let candidates = records.filter {
            $0.endpoint == endpoint && $0.key.algorithm == presented.algorithm
        }
        if candidates.contains(where: { $0.key == presented }) {
            return .trusted(fingerprint: presented.sha256Fingerprint)
        }
        guard !candidates.isEmpty else {
            return .unknown(presentedFingerprint: presented.sha256Fingerprint)
        }
        return .changed(
            presentedFingerprint: presented.sha256Fingerprint,
            trustedFingerprints: candidates.map(\.key.sha256Fingerprint).sorted()
        )
    }

    /// Persists an approval. `trustNew` cannot overwrite a changed key;
    /// callers must show the mismatch and pass `replaceChanged` deliberately.
    public func approve(
        endpoint: SSHHostKeyEndpoint,
        presented: SSHHostKey,
        approval: HostKeyApproval
    ) throws {
        let result = verification(endpoint: endpoint, presented: presented)
        switch (result, approval) {
        case (.trusted, _):
            return
        case (.unknown, .trustNew), (.unknown, .replaceChanged):
            records.append(SSHKnownHostRecord(endpoint: endpoint, key: presented))
        case (.changed, .replaceChanged):
            records.removeAll {
                $0.endpoint == endpoint && $0.key.algorithm == presented.algorithm
            }
            records.append(SSHKnownHostRecord(endpoint: endpoint, key: presented))
        case (.changed, .trustNew):
            throw HostKeyStoreError.changedKeyRequiresExplicitReplacement(result)
        }
        try Self.persist(records, to: fileURL)
    }

    public func remove(endpoint: SSHHostKeyEndpoint, algorithm: String? = nil) throws {
        records.removeAll {
            $0.endpoint == endpoint && (algorithm == nil || $0.key.algorithm == algorithm)
        }
        try Self.persist(records, to: fileURL)
    }

    private static func loadRecords(from url: URL) throws -> [SSHKnownHostRecord] {
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: parent.path) {
            try manager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard manager.fileExists(atPath: url.path) else {
            try Data().write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return []
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        var records: [SSHKnownHostRecord] = []
        for (offset, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  !fields[0].hasPrefix("@"),
                  let endpoint = try? endpoint(fromKnownHostsToken: String(fields[0])),
                  let key = try? SSHHostKey(
                      algorithm: String(fields[1]),
                      base64EncodedKey: String(fields[2])
                  )
            else {
                throw HostKeyStoreError.invalidKnownHostsLine(offset + 1)
            }
            records.append(SSHKnownHostRecord(endpoint: endpoint, key: key))
        }
        return records
    }

    private static func persist(_ records: [SSHKnownHostRecord], to url: URL) throws {
        let lines = records
            .sorted {
                if $0.endpoint.knownHostsToken != $1.endpoint.knownHostsToken {
                    return $0.endpoint.knownHostsToken < $1.endpoint.knownHostsToken
                }
                return $0.key.algorithm < $1.key.algorithm
            }
            .map { "\($0.endpoint.knownHostsToken) \($0.key.algorithm) \($0.key.base64EncodedKey)" }
        let data = Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func endpoint(fromKnownHostsToken token: String) throws -> SSHHostKeyEndpoint {
        if token.hasPrefix("["), let separator = token.lastIndex(of: "]") {
            let hostStart = token.index(after: token.startIndex)
            let host = String(token[hostStart ..< separator])
            let portStart = token.index(after: separator)
            guard token[portStart...].hasPrefix(":"),
                  let port = Int(token[token.index(after: portStart)...])
            else {
                throw SSHHostKeyEndpointError.invalidHost
            }
            return try SSHHostKeyEndpoint(host: host, port: port)
        }
        return try SSHHostKeyEndpoint(host: token)
    }
}

/// Extracts a displayable fingerprint from OpenSSH diagnostics. This is only
/// presentation evidence; a key is persisted solely through HostKeyStore.
public enum OpenSSHHostKeyDiagnosticParser {
    public static func fingerprint(in standardError: String) -> String? {
        for line in standardError.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "SHA256:") else { continue }
            let candidate = line[range.lowerBound...]
                .split(whereSeparator: { $0.isWhitespace || $0 == "." })
                .first
                .map(String.init)
            if let candidate, candidate.dropFirst("SHA256:".count).allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" || $0 == "-" || $0 == "_"
            }) {
                return candidate
            }
        }
        return nil
    }

    public static func reportsChangedKey(in standardError: String) -> Bool {
        standardError.localizedCaseInsensitiveContains("REMOTE HOST IDENTIFICATION HAS CHANGED")
    }
}
