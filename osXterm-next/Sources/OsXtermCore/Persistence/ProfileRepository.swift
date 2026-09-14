import Foundation

public enum ProfileRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case profileUsedAsJumpHost(dependentProfileNames: [String])

    public var errorDescription: String? {
        switch self {
        case let .profileUsedAsJumpHost(names):
            "This profile is used as a jump host by: \(names.joined(separator: ", ")). Edit those routes before deleting it."
        }
    }
}

public actor ProfileRepository {
    public static let applicationName = "osXterm"

    private let store: AtomicJSONStore<ProfileDocument>
    private var document: ProfileDocument

    public init(fileURL: URL? = nil) throws {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        store = AtomicJSONStore(fileURL: resolvedURL)
        document = try store.load(default: ProfileDocument())
        guard document.version == ProfileDocument.currentVersion else {
            throw AtomicJSONStoreError.unsupportedVersion(document.version)
        }
    }

    public func snapshot() -> ProfileDocument { document }

    public func profiles() -> [ConnectionProfile] { document.profiles }

    public func profile(id: UUID) -> ConnectionProfile? {
        document.profiles.first(where: { $0.id == id })
    }

    public func save(_ profile: ConnectionProfile) throws {
        var updated = document
        var value = profile
        value.updatedAt = .now
        if let index = updated.profiles.firstIndex(where: { $0.id == value.id }) {
            updated.profiles[index] = value
        } else {
            updated.profiles.append(value)
        }
        try commit(updated)
    }

    public func deleteProfile(id: UUID) throws {
        let dependents = document.profiles.filter { $0.id != id && $0.jumpProfileIDs.contains(id) }
        guard dependents.isEmpty else {
            // Removing the reference would silently change the next SSH,
            // SFTP, SCP or tunnel connection to a shorter, unintended route.
            throw ProfileRepositoryError.profileUsedAsJumpHost(
                dependentProfileNames: dependents.map(\.name).sorted()
            )
        }
        var updated = document
        updated.profiles.removeAll(where: { $0.id == id })
        try commit(updated)
    }

    public func saveFolder(_ folder: ConnectionFolder) throws {
        var updated = document
        if let index = updated.folders.firstIndex(where: { $0.id == folder.id }) {
            updated.folders[index] = folder
        } else {
            updated.folders.append(folder)
        }
        try commit(updated)
    }

    public func deleteFolder(id: UUID) throws {
        var updated = document
        updated.folders.removeAll(where: { $0.id == id })
        for index in updated.profiles.indices where updated.profiles[index].folderID == id {
            updated.profiles[index].folderID = nil
            updated.profiles[index].updatedAt = .now
        }
        try commit(updated)
    }

    private func commit(_ updated: ProfileDocument) throws {
        try store.save(updated)
        document = updated
    }

    public static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationName, isDirectory: true)
        return directory.appendingPathComponent("profiles.json")
    }
}
