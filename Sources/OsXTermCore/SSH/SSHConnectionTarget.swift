import Foundation

/// The resolved SSH endpoint used by both the interactive SSH and SFTP
/// builders. The Host field is authoritative whenever it is present, so an
/// `@` inside Username is preserved literally.
public struct SSHConnectionTarget: Equatable, Sendable {
    public let username: String
    public let host: String

    public init(username: String, host: String) {
        self.username = username
        self.host = host
    }

    /// Resolves a profile where the username field may contain a combined
    /// `username@realm@host` endpoint only when the Host field is empty.
    /// When Host is supplied separately, Username is never split or rewritten.
    public static func parse(host: String, username: String) -> Self? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            return nil
        }

        if !trimmedHost.isEmpty {
            return Self(username: trimmedUsername, host: trimmedHost)
        }

        let components = trimmedUsername.split(separator: "@", omittingEmptySubsequences: false)
        if components.count >= 3,
           let candidate = components.last,
           isHostCandidate(String(candidate))
        {
            let resolvedUsername = components.dropLast().map(String.init).joined(separator: "@")
            let resolvedHost = String(candidate)
            guard !resolvedUsername.isEmpty else {
                return nil
            }
            return Self(username: resolvedUsername, host: resolvedHost)
        }

        guard !trimmedHost.isEmpty else {
            return nil
        }
        return Self(username: trimmedUsername, host: trimmedHost)
    }

    private static func isHostCandidate(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              !value.contains("@"),
              !value.contains(","),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              })
        else {
            return false
        }

        return value == "localhost"
            || value.contains(".")
            || value.contains(":")
            || value.allSatisfy { $0.isNumber }
    }
}
