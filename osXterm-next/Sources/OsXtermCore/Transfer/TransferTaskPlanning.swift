import Foundation

public enum TransferPlanningError: Error, Equatable, Sendable, LocalizedError {
    case localURLMustBeFileURL
    case localURLIsOutsideAllowedRoot(URL)
    case localPathContainsNUL
    case remotePathIsEmpty
    case remotePathContainsNUL
    case remotePathIsUnsafeForSCP(String)
    case invalidTransferState(TransferState, TransferTaskEvent)
    case invalidProgress(bytesTransferred: Int64, totalBytes: Int64?)
    case invalidConflictRename(String)

    public var errorDescription: String? {
        switch self {
        case .localURLMustBeFileURL:
            "Transfer paths must be local file URLs."
        case let .localURLIsOutsideAllowedRoot(root):
            "Local transfer path is outside the allowed root: \(root.path)"
        case .localPathContainsNUL:
            "Local transfer path cannot contain NUL."
        case .remotePathIsEmpty:
            "Remote transfer path cannot be empty."
        case .remotePathContainsNUL:
            "Remote transfer path cannot contain NUL."
        case let .remotePathIsUnsafeForSCP(path):
            "Remote path cannot be safely sent through SCP: \(path)"
        case let .invalidTransferState(state, event):
            "Cannot apply \(event) while transfer is \(state.rawValue)."
        case let .invalidProgress(bytesTransferred, totalBytes):
            "Invalid transfer progress \(bytesTransferred) of \(String(describing: totalBytes))."
        case let .invalidConflictRename(name):
            "Invalid transfer conflict rename: \(name)"
        }
    }
}

public enum PlannedTransferProtocol: Sendable, Equatable {
    case sftp
    case scp
}

public enum PlannedTransferOperation: Sendable, Equatable {
    case upload
    case download
}

/// Validated transfer data. This is deliberately separate from process launch
/// so all callers share the same path and conflict policy checks.
public struct PlannedTransfer: Sendable, Equatable {
    public let taskID: UUID
    public let profileID: UUID
    public let protocolKind: PlannedTransferProtocol
    public let operation: PlannedTransferOperation
    public let localURL: URL
    public let remotePath: SFTPRemotePath
    public let isRecursive: Bool
    public let conflictPolicy: TransferConflictPolicy

    public init(
        taskID: UUID,
        profileID: UUID,
        protocolKind: PlannedTransferProtocol,
        operation: PlannedTransferOperation,
        localURL: URL,
        remotePath: SFTPRemotePath,
        isRecursive: Bool,
        conflictPolicy: TransferConflictPolicy
    ) {
        self.taskID = taskID
        self.profileID = profileID
        self.protocolKind = protocolKind
        self.operation = operation
        self.localURL = localURL
        self.remotePath = remotePath
        self.isRecursive = isRecursive
        self.conflictPolicy = conflictPolicy
    }
}

public enum TransferPlanner {
    /// Validates a persisted task immediately before it enters the transfer
    /// queue. `allowedLocalRoot` makes drag and drop destinations enforceable
    /// without trusting a UI-only check.
    public static func plan(
        _ task: TransferTask,
        allowedLocalRoot: URL? = nil
    ) throws -> PlannedTransfer {
        let localURL = try validateLocalURL(task.localURL, allowedRoot: allowedLocalRoot)
        let remotePath = try validateRemotePath(task.remotePath)

        let protocolKind: PlannedTransferProtocol
        let operation: PlannedTransferOperation
        switch task.direction {
        case .upload:
            protocolKind = .sftp
            operation = .upload
        case .download:
            protocolKind = .sftp
            operation = .download
        case .scpUpload:
            protocolKind = .scp
            operation = .upload
            try validateSCPRemotePath(remotePath.rawValue)
        case .scpDownload:
            protocolKind = .scp
            operation = .download
            try validateSCPRemotePath(remotePath.rawValue)
        }

        return PlannedTransfer(
            taskID: task.id,
            profileID: task.profileID,
            protocolKind: protocolKind,
            operation: operation,
            localURL: localURL,
            remotePath: remotePath,
            isRecursive: task.isRecursive,
            conflictPolicy: task.conflictPolicy
        )
    }

    public static func validateLocalURL(
        _ value: URL,
        allowedRoot: URL? = nil
    ) throws -> URL {
        guard value.isFileURL else {
            throw TransferPlanningError.localURLMustBeFileURL
        }
        guard !value.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TransferPlanningError.localPathContainsNUL
        }

        let normalized = value.standardizedFileURL
        if let allowedRoot {
            guard allowedRoot.isFileURL else {
                throw TransferPlanningError.localURLMustBeFileURL
            }
            let normalizedRoot = allowedRoot.standardizedFileURL.path
            let candidate = normalized.path
            let isAtRoot = candidate == normalizedRoot
            let isDescendant = candidate.hasPrefix(
                normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
            )
            guard isAtRoot || isDescendant else {
                throw TransferPlanningError.localURLIsOutsideAllowedRoot(allowedRoot)
            }
        }
        return normalized
    }

    public static func validateRemotePath(_ value: String) throws -> SFTPRemotePath {
        guard !value.isEmpty else {
            throw TransferPlanningError.remotePathIsEmpty
        }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TransferPlanningError.remotePathContainsNUL
        }
        return try SFTPRemotePath(rawValue: value)
    }

    /// Modern OpenSSH normally uses SFTP for `scp`, but a server or user can
    /// request legacy SCP behavior. Keep remote paths conservative at this
    /// boundary so a legacy remote shell never receives control syntax.
    public static func validateSCPRemotePath(_ value: String) throws {
        let unsafeScalars = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "'\\\"`$;&|<>(){}\\\\"))
        guard !value.unicodeScalars.contains(where: { unsafeScalars.contains($0) }) else {
            throw TransferPlanningError.remotePathIsUnsafeForSCP(value)
        }
    }

    public static func suggestedRename(
        for localURL: URL,
        ordinal: Int
    ) throws -> URL {
        guard ordinal > 0 else {
            throw TransferPlanningError.invalidConflictRename("Ordinal must be positive")
        }
        let fileName = localURL.lastPathComponent
        guard !fileName.isEmpty, !fileName.contains("\0") else {
            throw TransferPlanningError.invalidConflictRename(fileName)
        }

        let stem = localURL.deletingPathExtension().lastPathComponent
        let fileExtension = localURL.pathExtension
        let suffix = " \(ordinal)"
        let renamed = fileExtension.isEmpty
            ? stem + suffix
            : stem + suffix + "." + fileExtension
        return localURL.deletingLastPathComponent().appendingPathComponent(renamed)
    }
}

public enum TransferConflictDecision: Equatable, Sendable {
    case transfer
    case skip
    case requiresUserDecision
    case rename(URL)
}

public enum TransferConflictPlanner {
    public static func decide(
        policy: TransferConflictPolicy,
        destinationExists: Bool,
        destinationURL: URL,
        renameOrdinal: Int = 1
    ) throws -> TransferConflictDecision {
        guard destinationExists else { return .transfer }

        switch policy {
        case .overwrite:
            return .transfer
        case .skip:
            return .skip
        case .ask:
            return .requiresUserDecision
        case .rename:
            return .rename(try TransferPlanner.suggestedRename(for: destinationURL, ordinal: renameOrdinal))
        }
    }
}

/// A source fingerprint must match before a partial file can be resumed.
/// The coordinator records fingerprints from structured SFTP attributes or a
/// local file resource query and does not infer safety from a byte count alone.
public struct TransferSourceFingerprint: Codable, Equatable, Hashable, Sendable {
    public let size: Int64
    public let modificationTime: Date?

    public init(size: Int64, modificationTime: Date?) {
        self.size = size
        self.modificationTime = modificationTime
    }
}

public enum TransferResumeDecision: Equatable, Sendable {
    case restart
    case resume(fromOffset: Int64)
    /// The destination is a complete, digest-verified copy of the current
    /// source. Callers may count its bytes without opening it for writing.
    case alreadyComplete
}

public enum TransferResumePlanner {
    public static func decide(
        existingDestinationBytes: Int64,
        previousSource: TransferSourceFingerprint?,
        currentSource: TransferSourceFingerprint,
        prefixDigestMatches: Bool
    ) -> TransferResumeDecision {
        guard existingDestinationBytes > 0,
              existingDestinationBytes <= currentSource.size,
              previousSource == currentSource,
              prefixDigestMatches
        else {
            return .restart
        }
        if existingDestinationBytes == currentSource.size {
            return .alreadyComplete
        }
        return .resume(fromOffset: existingDestinationBytes)
    }
}

/// Identifies a single entry in an in-memory recursive transfer checkpoint.
/// Local and remote strings are deliberately distinct key spaces so a file
/// named like a remote path cannot select another direction's checkpoint.
public enum RecursiveTransferResumeKey: Hashable, Sendable {
    case localFile(path: String)
    case remoteFile(path: String)

    public static func localFile(at url: URL) throws -> Self {
        let localURL = try TransferPlanner.validateLocalURL(url)
        return .localFile(path: localURL.path)
    }

    public static func remoteFile(at path: SFTPRemotePath) -> Self {
        .remoteFile(path: path.rawValue)
    }
}

/// The resolved leaf destination is retained for a retry. This prevents a
/// recursive transfer with a rename policy from allocating a second name for
/// a partially transferred file.
public enum RecursiveTransferResumeDestination: Equatable, Sendable {
    case localFile(URL)
    case remoteFile(SFTPRemotePath)
}

public struct RecursiveTransferResumeCheckpoint: Equatable, Sendable {
    public let sourceFingerprint: TransferSourceFingerprint
    public let destination: RecursiveTransferResumeDestination

    public init(
        sourceFingerprint: TransferSourceFingerprint,
        destination: RecursiveTransferResumeDestination
    ) {
        self.sourceFingerprint = sourceFingerprint
        self.destination = destination
    }
}

/// Per-leaf checkpoint data for one managed transfer. It intentionally is not
/// Codable: a process restart has no trusted record of every resolved child,
/// so the coordinator restarts that recursive task under its normal conflict
/// policy instead of guessing which partial path can be appended.
public struct RecursiveTransferResumeLedger: Sendable {
    private var checkpoints: [RecursiveTransferResumeKey: RecursiveTransferResumeCheckpoint]
    private var directories: [RecursiveTransferResumeKey: RecursiveTransferResumeDestination]

    public init() {
        checkpoints = [:]
        directories = [:]
    }

    public func checkpoint(
        for key: RecursiveTransferResumeKey
    ) -> RecursiveTransferResumeCheckpoint? {
        checkpoints[key]
    }

    public mutating func record(
        _ checkpoint: RecursiveTransferResumeCheckpoint,
        for key: RecursiveTransferResumeKey
    ) {
        checkpoints[key] = checkpoint
    }

    public mutating func removeCheckpoint(for key: RecursiveTransferResumeKey) {
        checkpoints.removeValue(forKey: key)
    }

    public func directoryDestination(for key: RecursiveTransferResumeKey) -> RecursiveTransferResumeDestination? {
        directories[key]
    }

    public mutating func recordDirectory(
        _ destination: RecursiveTransferResumeDestination,
        for key: RecursiveTransferResumeKey
    ) {
        directories[key] = destination
    }
}

public enum TransferTaskEvent: Sendable, Equatable {
    case beginPreparation
    case begin(totalBytes: Int64?)
    case updateProgress(bytesTransferred: Int64, totalBytes: Int64?)
    case pause
    case resume
    case requestCancellation
    case cancel
    case complete
    case fail(message: String)
    case retry
}

/// Pure state reducer for a persisted queue task. It makes cancellation and
/// retry behavior explicit before process and network code are involved.
public enum TransferTaskStateMachine {
    public static func apply(
        _ event: TransferTaskEvent,
        to task: TransferTask
    ) throws -> TransferTask {
        var updated = task

        switch event {
        case .beginPreparation:
            try require(task.state == .queued, task: task, event: event)
            updated.state = .preparing

        case let .begin(totalBytes):
            try require(task.state == .preparing || task.state == .queued, task: task, event: event)
            try validateProgress(bytesTransferred: task.bytesTransferred, totalBytes: totalBytes)
            updated.state = .running
            updated.totalBytes = totalBytes
            updated.errorMessage = nil

        case let .updateProgress(bytesTransferred, totalBytes):
            try require(task.state == .running, task: task, event: event)
            let resolvedTotal = totalBytes ?? task.totalBytes
            try validateProgress(bytesTransferred: bytesTransferred, totalBytes: resolvedTotal)
            guard bytesTransferred >= task.bytesTransferred else {
                throw TransferPlanningError.invalidProgress(
                    bytesTransferred: bytesTransferred,
                    totalBytes: resolvedTotal
                )
            }
            updated.bytesTransferred = bytesTransferred
            updated.totalBytes = resolvedTotal

        case .pause:
            try require(task.state == .running, task: task, event: event)
            updated.state = .paused

        case .resume:
            try require(task.state == .paused, task: task, event: event)
            updated.state = .running

        case .requestCancellation:
            guard task.state == .queued || task.state == .preparing || task.state == .running || task.state == .paused else {
                throw TransferPlanningError.invalidTransferState(task.state, event)
            }
            updated.state = .cancelling

        case .cancel:
            guard task.state == .cancelling || task.state == .queued else {
                throw TransferPlanningError.invalidTransferState(task.state, event)
            }
            updated.state = .cancelled

        case .complete:
            try require(task.state == .running, task: task, event: event)
            if let total = task.totalBytes {
                guard task.bytesTransferred <= total else {
                    throw TransferPlanningError.invalidProgress(
                        bytesTransferred: task.bytesTransferred,
                        totalBytes: total
                    )
                }
                updated.bytesTransferred = total
            }
            updated.state = .completed
            updated.errorMessage = nil

        case let .fail(message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransferPlanningError.invalidTransferState(task.state, event)
            }
            guard task.state == .preparing || task.state == .running || task.state == .paused || task.state == .cancelling else {
                throw TransferPlanningError.invalidTransferState(task.state, event)
            }
            updated.state = .failed
            updated.errorMessage = message

        case .retry:
            guard task.state == .failed || task.state == .cancelled else {
                throw TransferPlanningError.invalidTransferState(task.state, event)
            }
            updated.state = .queued
            updated.bytesTransferred = 0
            updated.totalBytes = nil
            updated.errorMessage = nil
            updated.retryCount += 1
        }

        return updated
    }

    private static func require(
        _ condition: Bool,
        task: TransferTask,
        event: TransferTaskEvent
    ) throws {
        guard condition else {
            throw TransferPlanningError.invalidTransferState(task.state, event)
        }
    }

    private static func validateProgress(
        bytesTransferred: Int64,
        totalBytes: Int64?
    ) throws {
        guard bytesTransferred >= 0,
              totalBytes.map({ $0 >= 0 && bytesTransferred <= $0 }) ?? true
        else {
            throw TransferPlanningError.invalidProgress(
                bytesTransferred: bytesTransferred,
                totalBytes: totalBytes
            )
        }
    }
}
