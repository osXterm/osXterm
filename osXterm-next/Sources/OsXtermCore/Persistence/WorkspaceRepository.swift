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
        document.workspace = workspace
        document.workspace.updatedAt = .now
        try store.save(document)
    }

    public func updateSettings(_ settings: AppSettings) throws {
        document.settings = settings
        try store.save(document)
    }

    public func noteRecentProfile(_ profileID: UUID, maximumCount: Int = 32) throws {
        document.recentProfileIDs.removeAll(where: { $0 == profileID })
        document.recentProfileIDs.insert(profileID, at: 0)
        document.recentProfileIDs = Array(document.recentProfileIDs.prefix(max(1, maximumCount)))
        try store.save(document)
    }

    public func replaceSnippets(_ snippets: [CommandSnippet]) throws {
        document.snippets = snippets
        try store.save(document)
    }

    public static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProfileRepository.applicationName, isDirectory: true)
        return directory.appendingPathComponent("workspace.json")
    }
}
