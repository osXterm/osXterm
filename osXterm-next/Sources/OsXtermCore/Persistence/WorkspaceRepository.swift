import Foundation

/// Atomically stores ordinary app configuration under Application Support.
/// It contains no Keychain values and never persists a live process handle.
public actor WorkspaceRepository {
    private let store: AtomicJSONStore<AppWorkspaceDocument>
    private var document: AppWorkspaceDocument

    public init(fileURL: URL? = nil) throws {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        store = AtomicJSONStore(fileURL: resolvedURL)
        document = try store.load(default: AppWorkspaceDocument())
        guard document.version == AppWorkspaceDocument.currentVersion else {
            throw AtomicJSONStoreError.unsupportedVersion(document.version)
        }
    }

    public func snapshot() -> AppWorkspaceDocument { document }

    public func updateWorkspace(_ workspace: WorkspaceSnapshot) throws {
        var updated = document
        updated.workspace = workspace
        updated.workspace.updatedAt = .now
        try commit(updated)
    }

    public func updateSettings(_ settings: AppSettings) throws {
        var updated = document
        updated.settings = settings
        try commit(updated)
    }

    public func noteRecentProfile(_ profileID: UUID, maximumCount: Int = 32) throws {
        var updated = document
        updated.recentProfileIDs.removeAll(where: { $0 == profileID })
        updated.recentProfileIDs.insert(profileID, at: 0)
        updated.recentProfileIDs = Array(updated.recentProfileIDs.prefix(max(1, maximumCount)))
        try commit(updated)
    }

    public func replaceSnippets(_ snippets: [CommandSnippet]) throws {
        var updated = document
        updated.snippets = snippets
        try commit(updated)
    }

    private func commit(_ updated: AppWorkspaceDocument) throws {
        try store.save(updated)
        document = updated
    }

    public static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProfileRepository.applicationName, isDirectory: true)
        return directory.appendingPathComponent("workspace.json")
    }
}
