import Foundation
import OsXtermCore

enum AppWorkspaceServiceError: LocalizedError, Equatable {
    case unavailable
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            AppText.unavailable
        case let .unsupported(operation):
            AppText.string(
                "The core service does not support \(operation).",
                korean: "코어 서비스가 \(operation) 기능을 지원하지 않습니다."
            )
        }
    }
}

/// The one boundary between the UI and `OsXtermCore`.
///
/// A production adapter owns the domain model, credential store, terminal
/// engine, SFTP client and tunnel processes. The app only receives redacted
/// snapshots and sends explicit user intents through this protocol.
@MainActor
protocol AppWorkspaceService: AnyObject {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }

    func setSnapshotHandler(_ handler: @escaping @MainActor (AppWorkspaceSnapshot) -> Void)
    func loadSnapshot() async throws -> AppWorkspaceSnapshot

    func connect(profileID: UUID) async throws
    func startLocalTerminal() async throws
    func disconnect(sessionID: UUID) async throws
    func closeSession(id: UUID) async throws
    func selectSession(id: UUID?) async throws
    func setWorkspaceLayout(_ layout: WorkspaceLayoutPresentation) async throws
    func renameSession(id: UUID, title: String) async throws
    func duplicateSession(id: UUID) async throws
    func moveSession(id: UUID, toIndex: Int) async throws

    func profileDraft(for profileID: UUID) async throws -> ProfileDraftPresentation
    func saveProfile(_ submission: ProfileEditorSubmission) async throws
    func duplicateProfile(id: UUID) async throws
    func deleteProfile(id: UUID) async throws
    func setFavorite(profileID: UUID, isFavorite: Bool) async throws
    func saveFolder(id: UUID?, name: String) async throws
    func deleteFolder(id: UUID) async throws

    func previewSSHConfig(from url: URL) async throws -> SSHConfigImportPreviewPresentation
    func importSSHConfig(previewID: UUID, profileIDs: Set<UUID>) async throws
    func discardSSHConfigImportPreview(id: UUID) async
    func exportProfiles(ids: [UUID], to url: URL) async throws

    func enqueueUpload(urls: [URL], to sessionID: UUID, conflictPolicy: TransferConflictPolicy) async throws
    func enqueueSCPUpload(urls: [URL], to sessionID: UUID, conflictPolicy: TransferConflictPolicy) async throws
    func enqueueDownload(transferID: UUID, to url: URL, conflictPolicy: TransferConflictPolicy) async throws
    func refreshRemoteFiles(sessionID: UUID) async throws
    func navigateRemoteDirectory(path: String, sessionID: UUID) async throws
    func createRemoteDirectory(name: String, sessionID: UUID) async throws
    func renameRemoteFile(path: String, to name: String, sessionID: UUID) async throws
    func deleteRemoteFile(path: String, sessionID: UUID) async throws
    func changeRemotePermissions(path: String, permissions: String, sessionID: UUID) async throws
    func downloadRemoteFile(path: String, to url: URL, sessionID: UUID, conflictPolicy: TransferConflictPolicy) async throws
    func downloadRemoteFileViaSCP(path: String, to url: URL, sessionID: UUID, conflictPolicy: TransferConflictPolicy) async throws
    func openRemoteFileForEditing(path: String, sessionID: UUID) async throws -> RemoteEditPresentation
    func saveEditedRemoteFile(id: UUID) async throws
    func discardEditedRemoteFile(id: UUID) async throws
    func cancelTransfer(id: UUID) async throws
    func retryTransfer(id: UUID) async throws

    func startTunnel(id: UUID) async throws
    func stopTunnel(id: UUID) async throws
    func restartTunnel(id: UUID) async throws
    func probeTunnelDestination(id: UUID) async throws
    func saveTunnel(_ draft: ForwardingDraftPresentation, sessionID: UUID?) async throws
    func deleteTunnel(id: UUID) async throws

    func runSnippet(id: UUID, on sessionIDs: Set<UUID>, values: [UUID: String]) async throws
    func saveSnippet(title: String, commandsText: String) async throws
    func updateSnippet(id: UUID, title: String, commandsText: String) async throws
    func deleteSnippet(id: UUID) async throws
    func setBroadcastTargets(_ sessionIDs: Set<UUID>) async throws
    func terminalProcessDidStart(sessionID: UUID, launchID: UUID) async throws
    func terminalProcessDidTerminate(sessionID: UUID, launchID: UUID, exitCode: Int32?) async throws
    func terminalProcessDidOutput(sessionID: UUID, launchID: UUID, data: Data) async throws
    func terminalInputDidSend(_ data: Data, from sessionID: UUID) async throws
    func terminalDidResize(sessionID: UUID, columns: Int, rows: Int) async throws
    func updateSettings(_ settings: AppSettingsPresentation) async throws
    func respond(to challengeID: UUID, response: String?) async throws
    func shutdown()
}

extension AppWorkspaceService {
    var unavailableReason: String? { nil }

    func setSnapshotHandler(_: @escaping @MainActor (AppWorkspaceSnapshot) -> Void) {}

    func connect(profileID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("connections") }
    func startLocalTerminal() async throws { throw AppWorkspaceServiceError.unsupported("local terminals") }
    func disconnect(sessionID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("session shutdown") }
    func closeSession(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("session close") }
    func selectSession(id _: UUID?) async throws { throw AppWorkspaceServiceError.unsupported("session selection") }
    func setWorkspaceLayout(_: WorkspaceLayoutPresentation) async throws { throw AppWorkspaceServiceError.unsupported("workspace layout") }
    func renameSession(id _: UUID, title _: String) async throws { throw AppWorkspaceServiceError.unsupported("session rename") }
    func duplicateSession(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("session duplication") }
    func moveSession(id _: UUID, toIndex _: Int) async throws { throw AppWorkspaceServiceError.unsupported("session ordering") }

    func profileDraft(for _: UUID) async throws -> ProfileDraftPresentation { throw AppWorkspaceServiceError.unsupported("profile editing") }
    func saveProfile(_: ProfileEditorSubmission) async throws { throw AppWorkspaceServiceError.unsupported("profile saving") }
    func duplicateProfile(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("profile duplication") }
    func deleteProfile(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("profile deletion") }
    func setFavorite(profileID _: UUID, isFavorite _: Bool) async throws { throw AppWorkspaceServiceError.unsupported("favorites") }
    func saveFolder(id _: UUID?, name _: String) async throws { throw AppWorkspaceServiceError.unsupported("folders") }
    func deleteFolder(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("folders") }

    func previewSSHConfig(from _: URL) async throws -> SSHConfigImportPreviewPresentation { throw AppWorkspaceServiceError.unsupported("SSH config import preview") }
    func importSSHConfig(previewID _: UUID, profileIDs _: Set<UUID>) async throws { throw AppWorkspaceServiceError.unsupported("SSH config import") }
    func discardSSHConfigImportPreview(id _: UUID) async {}
    func exportProfiles(ids _: [UUID], to _: URL) async throws { throw AppWorkspaceServiceError.unsupported("profile export") }

    func enqueueUpload(urls _: [URL], to _: UUID, conflictPolicy _: TransferConflictPolicy) async throws { throw AppWorkspaceServiceError.unsupported("uploads") }
    func enqueueSCPUpload(urls _: [URL], to _: UUID, conflictPolicy _: TransferConflictPolicy) async throws { throw AppWorkspaceServiceError.unsupported("SCP uploads") }
    func enqueueDownload(transferID _: UUID, to _: URL, conflictPolicy _: TransferConflictPolicy) async throws { throw AppWorkspaceServiceError.unsupported("downloads") }
    func refreshRemoteFiles(sessionID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote file listing") }
    func navigateRemoteDirectory(path _: String, sessionID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote directory navigation") }
    func createRemoteDirectory(name _: String, sessionID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote directory creation") }
    func renameRemoteFile(path _: String, to _: String, sessionID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote file rename") }
    func deleteRemoteFile(path _: String, sessionID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote file deletion") }
    func changeRemotePermissions(path _: String, permissions _: String, sessionID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote permissions") }
    func downloadRemoteFile(path _: String, to _: URL, sessionID _: UUID, conflictPolicy _: TransferConflictPolicy) async throws { throw AppWorkspaceServiceError.unsupported("remote download") }
    func downloadRemoteFileViaSCP(path _: String, to _: URL, sessionID _: UUID, conflictPolicy _: TransferConflictPolicy) async throws { throw AppWorkspaceServiceError.unsupported("SCP download") }
    func openRemoteFileForEditing(path _: String, sessionID _: UUID) async throws -> RemoteEditPresentation { throw AppWorkspaceServiceError.unsupported("remote file editing") }
    func saveEditedRemoteFile(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote file editing") }
    func discardEditedRemoteFile(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("remote file editing") }
    func cancelTransfer(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("transfer cancellation") }
    func retryTransfer(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("transfer retries") }

    func startTunnel(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("tunnel start") }
    func stopTunnel(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("tunnel stop") }
    func restartTunnel(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("tunnel restart") }
    func probeTunnelDestination(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("tunnel destination probes") }
    func saveTunnel(_: ForwardingDraftPresentation, sessionID _: UUID?) async throws { throw AppWorkspaceServiceError.unsupported("tunnel editing") }
    func deleteTunnel(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("tunnel deletion") }

    func runSnippet(id _: UUID, on _: Set<UUID>, values _: [UUID: String]) async throws { throw AppWorkspaceServiceError.unsupported("snippets") }
    func saveSnippet(title _: String, commandsText _: String) async throws { throw AppWorkspaceServiceError.unsupported("snippets") }
    func updateSnippet(id _: UUID, title _: String, commandsText _: String) async throws { throw AppWorkspaceServiceError.unsupported("snippets") }
    func deleteSnippet(id _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("snippets") }
    func setBroadcastTargets(_: Set<UUID>) async throws { throw AppWorkspaceServiceError.unsupported("broadcast input") }
    func terminalProcessDidStart(sessionID _: UUID, launchID _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("terminal launch") }
    func terminalProcessDidTerminate(sessionID _: UUID, launchID _: UUID, exitCode _: Int32?) async throws { throw AppWorkspaceServiceError.unsupported("terminal lifecycle") }
    func terminalProcessDidOutput(sessionID _: UUID, launchID _: UUID, data _: Data) async throws { throw AppWorkspaceServiceError.unsupported("terminal output") }
    func terminalInputDidSend(_: Data, from _: UUID) async throws { throw AppWorkspaceServiceError.unsupported("terminal input") }
    func terminalDidResize(sessionID _: UUID, columns _: Int, rows _: Int) async throws { throw AppWorkspaceServiceError.unsupported("terminal resize") }
    func updateSettings(_: AppSettingsPresentation) async throws { throw AppWorkspaceServiceError.unsupported("settings") }
    func respond(to _: UUID, response _: String?) async throws { throw AppWorkspaceServiceError.unsupported("authentication") }
    func shutdown() {}
}

@MainActor
final class UnconfiguredWorkspaceService: AppWorkspaceService {
    let isAvailable = false
    let unavailableReason: String?

    init(reason: String? = nil) {
        unavailableReason = reason ?? AppText.unavailable
    }

    func loadSnapshot() async throws -> AppWorkspaceSnapshot {
        throw AppWorkspaceServiceError.unavailable
    }
}
