import Foundation

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
        var value = profile
        value.updatedAt = .now
        if let index = document.profiles.firstIndex(where: { $0.id == value.id }) {
            document.profiles[index] = value
        } else {
            document.profiles.append(value)
        }
        try store.save(document)
    }

    public func deleteProfile(id: UUID) throws {
        document.profiles.removeAll(where: { $0.id == id })
        for index in document.profiles.indices {
            document.profiles[index].jumpProfileIDs.removeAll(where: { $0 == id })
            document.profiles[index].updatedAt = .now
        }
        try store.save(document)
    }

    public func saveFolder(_ folder: ConnectionFolder) throws {
        if let index = document.folders.firstIndex(where: { $0.id == folder.id }) {
            document.folders[index] = folder
        } else {
            document.folders.append(folder)
        }
        try store.save(document)
    }

    public func deleteFolder(id: UUID) throws {
        document.folders.removeAll(where: { $0.id == id })
        for index in document.profiles.indices where document.profiles[index].folderID == id {
            document.profiles[index].folderID = nil
            document.profiles[index].updatedAt = .now
        }
        try store.save(document)
    }

    public static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationName, isDirectory: true)
        return directory.appendingPathComponent("profiles.json")
    }
}
