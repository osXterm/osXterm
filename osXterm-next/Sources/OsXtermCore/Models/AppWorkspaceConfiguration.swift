import Foundation

public enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// Persisted presentation preferences. These values are deliberately separate
/// from the UI framework so they can be atomically stored with a schema
/// version and restored without serializing an AppKit or SwiftUI object.
public struct AppSettings: Codable, Equatable, Sendable {
    public var appearance: AppAppearance
    public var terminalFontName: String
    public var terminalFontSize: Double
    public var terminalLineSpacing: Double
    public var terminalThemeName: String
    public var allowRemoteClipboard: Bool
    public var keepTunnelsRunningWhenWindowCloses: Bool
    public var sessionLoggingEnabled: Bool

    public init(
        appearance: AppAppearance = .system,
        terminalFontName: String = "SF Mono",
        terminalFontSize: Double = 13,
        terminalLineSpacing: Double = 1,
        terminalThemeName: String = "System",
        allowRemoteClipboard: Bool = false,
        keepTunnelsRunningWhenWindowCloses: Bool = true,
        sessionLoggingEnabled: Bool = false
    ) {
        self.appearance = appearance
        self.terminalFontName = terminalFontName
        self.terminalFontSize = terminalFontSize
        self.terminalLineSpacing = terminalLineSpacing
        self.terminalThemeName = terminalThemeName
        self.allowRemoteClipboard = allowRemoteClipboard
        self.keepTunnelsRunningWhenWindowCloses = keepTunnelsRunningWhenWindowCloses
        self.sessionLoggingEnabled = sessionLoggingEnabled
    }

    public static let `default` = AppSettings()
}

public struct CommandSnippetVariable: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var prompt: String
    public var isSecret: Bool

    public init(id: UUID = UUID(), name: String, prompt: String, isSecret: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isSecret = isSecret
    }
}

/// A command sequence is saved only as user-authored text. The runtime must
/// never run one while restoring a workspace.
public struct CommandSnippet: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var commands: [String]
    public var variables: [CommandSnippetVariable]

    public init(
        id: UUID = UUID(),
        title: String,
        commands: [String],
        variables: [CommandSnippetVariable] = []
    ) {
        self.id = id
        self.title = title
        self.commands = commands
        self.variables = variables
    }
}

public struct AppWorkspaceDocument: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var workspace: WorkspaceSnapshot
    public var settings: AppSettings
    public var recentProfileIDs: [UUID]
    public var snippets: [CommandSnippet]

    public init(
        version: Int = AppWorkspaceDocument.currentVersion,
        workspace: WorkspaceSnapshot = WorkspaceSnapshot(name: "Default"),
        settings: AppSettings = .default,
        recentProfileIDs: [UUID] = [],
        snippets: [CommandSnippet] = []
    ) {
        self.version = version
        self.workspace = workspace
        self.settings = settings
        self.recentProfileIDs = recentProfileIDs
        self.snippets = snippets
    }
}
