import Foundation

public enum ConnectionStage: String, Codable, Sendable {
    case idle
    case resolvingRoute
    case preparingAuthentication
    case verifyingHostKey
    case launching
    case waitingForAuthentication
    case openingChannels
    case connected
    case stopping
}

public enum SessionState: Codable, Equatable, Sendable {
    case idle
    case connecting(ConnectionStage)
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case stopping
    case stopped(exitCode: Int32?)
    case failed(message: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case stage
        case attempt
        case exitCode
        case message
    }

    private enum Kind: String, Codable {
        case idle, connecting, authenticating, connected, reconnecting, stopping, stopped, failed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .connecting: self = .connecting(try values.decode(ConnectionStage.self, forKey: .stage))
        case .authenticating: self = .authenticating
        case .connected: self = .connected
        case .reconnecting: self = .reconnecting(attempt: try values.decode(Int.self, forKey: .attempt))
        case .stopping: self = .stopping
        case .stopped: self = .stopped(exitCode: try values.decodeIfPresent(Int32.self, forKey: .exitCode))
        case .failed: self = .failed(message: try values.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try values.encode(Kind.idle, forKey: .kind)
        case let .connecting(stage):
            try values.encode(Kind.connecting, forKey: .kind)
            try values.encode(stage, forKey: .stage)
        case .authenticating:
            try values.encode(Kind.authenticating, forKey: .kind)
        case .connected:
            try values.encode(Kind.connected, forKey: .kind)
        case let .reconnecting(attempt):
            try values.encode(Kind.reconnecting, forKey: .kind)
            try values.encode(attempt, forKey: .attempt)
        case .stopping:
            try values.encode(Kind.stopping, forKey: .kind)
        case let .stopped(exitCode):
            try values.encode(Kind.stopped, forKey: .kind)
            try values.encodeIfPresent(exitCode, forKey: .exitCode)
        case let .failed(message):
            try values.encode(Kind.failed, forKey: .kind)
            try values.encode(message, forKey: .message)
        }
    }
}

public enum TunnelStatus: Codable, Equatable, Sendable {
    case stopped
    case starting
    case listening(assignedPort: Int?)
    case probing
    case reachable
    case failed(message: String)

    public var isActive: Bool {
        switch self {
        case .starting, .listening, .probing, .reachable: true
        case .stopped, .failed: false
        }
    }
}

public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
    case scpUpload
    case scpDownload
}

public enum TransferState: String, Codable, Sendable {
    case queued
    case preparing
    case running
    case paused
    case cancelling
    case cancelled
    case completed
    case failed
}

public enum TransferConflictPolicy: String, Codable, Sendable {
    case ask
    case overwrite
    case skip
    case rename
}

public struct TransferTask: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var direction: TransferDirection
    public var localURL: URL
    public var remotePath: String
    public var isRecursive: Bool
    public var conflictPolicy: TransferConflictPolicy
    public var state: TransferState
    public var bytesTransferred: Int64
    public var totalBytes: Int64?
    /// Retained only for the lifetime of an in-app queued transfer. A retry
    /// compares this with the current source before it ever appends bytes.
    public var sourceFingerprint: TransferSourceFingerprint?
    public var errorMessage: String?
    public var retryCount: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        direction: TransferDirection,
        localURL: URL,
        remotePath: String,
        isRecursive: Bool = false,
        conflictPolicy: TransferConflictPolicy = .ask,
        state: TransferState = .queued,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64? = nil,
        sourceFingerprint: TransferSourceFingerprint? = nil,
        errorMessage: String? = nil,
        retryCount: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.isRecursive = isRecursive
        self.conflictPolicy = conflictPolicy
        self.state = state
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.sourceFingerprint = sourceFingerprint
        self.errorMessage = errorMessage
        self.retryCount = retryCount
        self.createdAt = createdAt
    }
}
