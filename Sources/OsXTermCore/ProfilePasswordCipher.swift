import CryptoKit
import Foundation

/// Encrypts profile passwords before they are written to profiles.json.
///
/// The key is generated once in the osXterm configuration directory and is
/// restricted to the current user. Passwords never enter the SSH command line,
/// process environment, or macOS Keychain.
public struct ProfilePasswordCipher: Sendable {
    public enum CipherError: Error, Equatable, Sendable {
        case emptyPassword
        case configurationDirectoryUnavailable
        case invalidKey
        case invalidCiphertext
        case invalidStoredPassword
    }

    public static let shared = ProfilePasswordCipher()

    private let keyURL: URL
    private let legacyKeyURLs: [URL]

    public init(keyURL: URL? = nil) {
        if let keyURL {
            self.keyURL = keyURL
            legacyKeyURLs = []
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let activeConfigurationDirectory = home
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("osXterm", isDirectory: true)
            self.keyURL = activeConfigurationDirectory
                .appendingPathComponent(".password-key", isDirectory: false)
            let legacyConfigurationDirectory = home
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent(Self.legacyProductDirectoryName, isDirectory: true)
            let legacyApplicationSupportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent(Self.legacyProductDirectoryName, isDirectory: true)
            legacyKeyURLs = [
                legacyConfigurationDirectory.appendingPathComponent(".password-key", isDirectory: false),
                legacyApplicationSupportDirectory?.appendingPathComponent(".password-key", isDirectory: false)
            ].compactMap { $0 }
        }
    }

    public func encrypt(_ password: String) throws -> String {
        guard !password.isEmpty else {
            throw CipherError.emptyPassword
        }

        let sealed = try AES.GCM.seal(Data(password.utf8), using: loadOrCreateKey())
        guard let combined = sealed.combined else {
            throw CipherError.invalidCiphertext
        }
        return "v1:\(combined.base64EncodedString())"
    }

    public func decrypt(_ ciphertext: String) throws -> String {
        guard ciphertext.hasPrefix("v1:"),
              let combined = Data(base64Encoded: String(ciphertext.dropFirst(3)))
        else {
            throw CipherError.invalidCiphertext
        }

        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let cleartext = try AES.GCM.open(sealed, using: loadOrCreateKey())
            guard let password = String(data: cleartext, encoding: .utf8), !password.isEmpty else {
                throw CipherError.invalidStoredPassword
            }
            return password
        } catch let error as CipherError {
            throw error
        } catch {
            throw CipherError.invalidCiphertext
        }
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        let fileManager = FileManager.default
        let directory = keyURL.deletingLastPathComponent()
        guard !directory.path.isEmpty else {
            throw CipherError.configurationDirectoryUnavailable
        }

        if fileManager.fileExists(atPath: keyURL.path) {
            return try Self.readKey(at: keyURL)
        }

        if let legacyKeyURL = legacyKeyURLs.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) {
            let key = try Self.readKey(at: legacyKeyURL)
            let data = key.withUnsafeBytes { Data($0) }
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try data.write(to: keyURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
            return key
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        // AES-GCM protects the password value. The file itself only needs
        // private POSIX permissions; macOS file-protection classes can make a
        // key created by a GUI app unreadable to the child ssh process.
        try data.write(to: keyURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyURL.path
        )
        return key
    }

    private static func readKey(at url: URL) throws -> SymmetricKey {
        let data = try Data(contentsOf: url)
        guard data.count == 32 else {
            throw CipherError.invalidKey
        }
        return SymmetricKey(data: data)
    }

    private static let legacyProductDirectoryName = "ma" + "Xterm"
}
