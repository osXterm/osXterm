import Foundation

public enum TerminalSessionKind: Codable, Hashable, Sendable {
    case localShell
    case profile(UUID)
}

public struct TerminalSessionDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: TerminalSessionKind
    public var shouldLog: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        kind: TerminalSessionKind,
        shouldLog: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.shouldLog = shouldLog
    }
}

public enum WorkspaceSplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public indirect enum TerminalLayoutNode: Codable, Hashable, Sendable {
    case session(UUID)
    case split(axis: WorkspaceSplitAxis, ratio: Double, leading: TerminalLayoutNode, trailing: TerminalLayoutNode)
}

public struct WorkspaceSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sessions: [TerminalSessionDescriptor]
    public var layout: TerminalLayoutNode?
    public var selectedSessionID: UUID?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sessions: [TerminalSessionDescriptor] = [],
        layout: TerminalLayoutNode? = nil,
        selectedSessionID: UUID? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.layout = layout
        self.selectedSessionID = selectedSessionID
        self.updatedAt = updatedAt
    }
}
