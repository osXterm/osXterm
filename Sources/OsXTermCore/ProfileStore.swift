import Foundation

public actor ProfileStore {
    public enum StoreError: Error, LocalizedError, Sendable {
        case configurationDirectoryUnavailable
        case unreadableFile(URL, String)
        case recoveryFailed(URL, String)

        public var errorDescription: String? {
            switch self {
            case .configurationDirectoryUnavailable:
                return "The osXterm configuration directory is unavailable."
            case let .unreadableFile(url, reason):
                return "The osXterm settings file could not be read at \(url.path): \(reason)"
            case let .recoveryFailed(url, reason):
                return "The osXterm settings backup could not be completed at \(url.path): \(reason)"
            }
        }
    }

    private let fileURL: URL
    private let legacyFileURLs: [URL]
    private let passwordKeyURLs: [URL]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL
            legacyFileURLs = []
            passwordKeyURLs = [fileURL.deletingLastPathComponent().appendingPathComponent(".password-key", isDirectory: false)]
        } else {
            let userDirectory = FileManager.default.homeDirectoryForCurrentUser
            guard !userDirectory.path.isEmpty else {
                throw StoreError.configurationDirectoryUnavailable
            }

            let activeFileURL = userDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("osXterm", isDirectory: true)
                .appendingPathComponent("profiles.json", isDirectory: false)
            self.fileURL = activeFileURL

            let legacyConfigurationDirectory = userDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent(Self.legacyProductDirectoryName, isDirectory: true)
            let legacyApplicationSupportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent(Self.legacyProductDirectoryName, isDirectory: true)
            legacyFileURLs = [
                legacyConfigurationDirectory.appendingPathComponent("profiles.json", isDirectory: false),
                legacyApplicationSupportDirectory?.appendingPathComponent("profiles.json", isDirectory: false)
            ].compactMap { $0 }
            passwordKeyURLs = [
                activeFileURL.deletingLastPathComponent().appendingPathComponent(".password-key", isDirectory: false),
                legacyConfigurationDirectory.appendingPathComponent(".password-key", isDirectory: false),
                legacyApplicationSupportDirectory?.appendingPathComponent(".password-key", isDirectory: false)
            ].compactMap { $0 }
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> [SSHProfile] {
        let sourceURL: URL
        let isLegacyMigration: Bool
        if FileManager.default.fileExists(atPath: fileURL.path) {
            sourceURL = fileURL
            isLegacyMigration = false
        } else if let legacyFileURL = legacyFileURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            sourceURL = legacyFileURL
            isLegacyMigration = true
        } else {
            return []
        }

        let storedData: Data
        do {
            storedData = try Data(contentsOf: sourceURL)
        } catch {
            throw StoreError.unreadableFile(sourceURL, error.localizedDescription)
        }
        let decodedProfiles = try decoder.decode([SSHProfile].self, from: storedData)
        let profiles = SSHRouteResolver.migrateLegacyProfiles(
            decodedProfiles.map(Self.normalizedProfile)
        )

        // Re-encode legacy profile shapes after decoding them. This removes an
        // old opaque credential reference without reading or deleting any
        // external credential store entry.
        let sanitizedData = try encoder.encode(profiles)
        if isLegacyMigration || sanitizedData != storedData {
            try write(sanitizedData)
        }

        return profiles
    }

    /// Moves an unreadable profile file and its paired password key together
    /// so a fresh configuration can be created without deleting user data.
    /// The caller must explicitly choose this recovery action.
    @discardableResult
    public func recoverUnreadableConfiguration() throws -> URL {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        guard !directory.path.isEmpty else {
            throw StoreError.configurationDirectoryUnavailable
        }

        let profileSource: URL?
        if fileManager.fileExists(atPath: fileURL.path) {
            profileSource = fileURL
        } else if let legacyFileURL = legacyFileURLs.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) {
            profileSource = legacyFileURL
        } else {
            profileSource = nil
        }
        let sourceURLs = ([profileSource] + passwordKeyURLs).compactMap { $0 }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !sourceURLs.isEmpty else {
            throw StoreError.configurationDirectoryUnavailable
        }

        let recoveryRoot = directory.appendingPathComponent("recovery", isDirectory: true)
        try fileManager.createDirectory(
            at: recoveryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: recoveryRoot.path
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let backupDirectory = recoveryRoot.appendingPathComponent(
            formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"),
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var moved: [(source: URL, destination: URL)] = []
        do {
            for sourceURL in sourceURLs {
                let baseName = sourceURL.lastPathComponent
                var destinationURL = backupDirectory.appendingPathComponent(
                    baseName,
                    isDirectory: false
                )
                var duplicateNumber = 2
                while fileManager.fileExists(atPath: destinationURL.path) {
                    destinationURL = backupDirectory.appendingPathComponent(
                        "\(baseName)-\(duplicateNumber)",
                        isDirectory: false
                    )
                    duplicateNumber += 1
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationURL.path
                )
                moved.append((sourceURL, destinationURL))
            }
        } catch {
            for item in moved.reversed() {
                try? fileManager.moveItem(at: item.destination, to: item.source)
            }
            throw StoreError.recoveryFailed(backupDirectory, error.localizedDescription)
        }

        return backupDirectory
    }

    public func save(_ profiles: [SSHProfile]) throws {
        let migrated = SSHRouteResolver.migrateLegacyProfiles(profiles)
        try write(encoder.encode(migrated))
    }

    private func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func normalizedProfile(_ profile: SSHProfile) -> SSHProfile {
        var normalized = profile
        if let target = SSHConnectionTarget.parse(
            host: profile.host,
            username: profile.username
        ) {
            normalized.host = target.host
            normalized.username = target.username
        }
        return normalized
    }

    private static let legacyProductDirectoryName = "ma" + "Xterm"
}
