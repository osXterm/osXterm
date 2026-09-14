import CryptoKit
import Foundation
import OsXtermCore

enum CoreWorkspaceServiceError: LocalizedError, Equatable {
    case profileNotFound
    case sessionNotFound
    case sessionNotReady
    case sessionLogUnavailable
    case sessionLogExportFailed
    case tunnelNotFound
    case transferNotFound
    case invalidProfile(String)
    case invalidForwarding(String)
    case helperUnavailable(String)
    case unsupportedSnippetInput

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            AppText.string("The selected connection no longer exists.", korean: "선택한 연결이 더 이상 없습니다.")
        case .sessionNotFound:
            AppText.string("The selected terminal session no longer exists.", korean: "선택한 터미널 세션이 더 이상 없습니다.")
        case .sessionNotReady:
            AppText.string("Wait for the SSH session to finish connecting.", korean: "SSH 세션 연결이 완료될 때까지 기다리세요.")
        case .sessionLogUnavailable:
            AppText.string("No recorded log is available for this session.", korean: "이 세션에서 기록된 로그를 찾을 수 없습니다.")
        case .sessionLogExportFailed:
            AppText.string("The session log could not be exported. Check the selected folder and try again.", korean: "세션 로그를 내보낼 수 없습니다. 선택한 폴더를 확인한 뒤 다시 시도하세요.")
        case .tunnelNotFound:
            AppText.string("The selected tunnel no longer exists.", korean: "선택한 터널이 더 이상 없습니다.")
        case .transferNotFound:
            AppText.string("The selected transfer no longer exists.", korean: "선택한 전송이 더 이상 없습니다.")
        case let .invalidProfile(message), let .invalidForwarding(message):
            message
        case let .helperUnavailable(name):
            AppText.string(
                "The packaged \(name) helper is unavailable.",
                korean: "패키지에 포함된 \(name) helper를 찾을 수 없습니다."
            )
        case .unsupportedSnippetInput:
            AppText.string(
                "This snippet needs variables and cannot run until values are supplied.",
                korean: "이 스니펫에는 변수 값이 필요하므로 값을 입력하기 전에는 실행할 수 없습니다."
            )
        }
    }
}

/// A credential helper runs off the main thread. This gate transfers only a
/// prompt and a one-time response between that helper and the visible app.
/// It never writes the response to a profile, export, terminal log, or command
/// line. The object uses a condition because the AskPass IPC request itself is
/// synchronous by OpenSSH design.
private final class CredentialChallengeGate: @unchecked Sendable {
    private enum Outcome {
        case waiting
        case resolved(String?)
    }

    typealias Presenter = @Sendable (AuthenticationChallengePresentation) -> Void

    private let sessionID: UUID
    private let condition = NSCondition()
    private var outcomes: [UUID: Outcome] = [:]
    var presenter: Presenter?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    func requestResponse(for request: CredentialBrokerRequest) -> String? {
        let prompt = OpenSSHOutputSanitizer.displayMessage(request.prompt, limit: 1_024)
        let lower = prompt.lowercased()
        let isHostKeyPrompt = lower.contains("continue connecting")
            || lower.contains("authenticity of host")
            || lower.contains("host key") && lower.contains("yes/no")
        let fingerprint = OpenSSHHostKeyDiagnosticParser.fingerprint(in: prompt)
            ?? AppText.string("Fingerprint unavailable", korean: "fingerprint를 가져올 수 없음")
        let kind: AuthenticationChallengeKindPresentation = isHostKeyPrompt
            ? .hostKeyNew(fingerprint: fingerprint)
            : .credential
        let isSecure = !isHostKeyPrompt
        let challenge = AuthenticationChallengePresentation(
            sessionID: sessionID,
            prompt: prompt.isEmpty
                ? AppText.string("Authentication response required", korean: "인증 응답이 필요합니다")
                : prompt,
            isSecure: isSecure,
            attemptDescription: request.purpose == .proxy
                ? AppText.string("Proxy authentication", korean: "프록시 인증")
                : nil,
            kind: kind
        )

        condition.lock()
        outcomes[challenge.id] = .waiting
        condition.unlock()
        presenter?(challenge)

        let deadline = Date().addingTimeInterval(180)
        condition.lock()
        defer { condition.unlock() }
        while case .waiting? = outcomes[challenge.id] {
            if !condition.wait(until: deadline) {
                outcomes.removeValue(forKey: challenge.id)
                return nil
            }
        }
        guard case let .resolved(response)? = outcomes.removeValue(forKey: challenge.id) else {
            return nil
        }
        if isHostKeyPrompt {
            return response == "trust-new-host-key" ? "yes" : nil
        }
        return response
    }

    func resolve(challengeID: UUID, response: String?) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard case .waiting? = outcomes[challengeID] else { return false }
        outcomes[challengeID] = .resolved(response)
        condition.broadcast()
        return true
    }

    func cancelAll() {
        condition.lock()
        for id in outcomes.keys {
            outcomes[id] = .resolved(nil)
        }
        condition.broadcast()
        condition.unlock()
    }
}

private final class ManagedTerminalSession {
    let id: UUID
    var descriptor: TerminalSessionDescriptor
    let profileID: UUID?
    let isLocal: Bool
    var state: SessionPresentationState
    var launch: TerminalProcessLaunchPresentation?
    var route: ResolvedSSHRoute?
    var preparedCommand: PreparedOpenSSHCommand?
    var credentialBroker: SessionCredentialBroker?
    var challengeGate: CredentialChallengeGate?
    var outputTail = Data()
    var userRequestedStop = false
    var reconnectAttempts = 0
    var currentDirectory: String?
    var logFile: FileHandle?
    var nextInputSequence: UInt64 = 0
    var pendingInput: TerminalInputPresentation?

    init(
        descriptor: TerminalSessionDescriptor,
        state: SessionPresentationState = .disconnected,
        launch: TerminalProcessLaunchPresentation? = nil
    ) {
        id = descriptor.id
        self.descriptor = descriptor
        switch descriptor.kind {
        case .localShell:
            profileID = nil
            isLocal = true
        case let .profile(profileID):
            self.profileID = profileID
            isLocal = false
        }
        self.state = state
        self.launch = launch
    }

    deinit {
        logFile?.closeFile()
        credentialBroker?.stop()
        preparedCommand?.configuration.cleanup()
    }
}

private final class ManagedTunnel {
    let id: UUID
    var rule: ForwardingRule
    let profileID: UUID
    var sessionID: UUID?
    var isIndependent: Bool
    var phase: TunnelPhasePresentation = .stopped
    var assignedPort: Int?
    var destinationReachability: TunnelDestinationReachability
    var process: Process?
    var preparedCommand: PreparedOpenSSHCommand?
    var credentialBroker: SessionCredentialBroker?
    var challengeGate: CredentialChallengeGate?
    var userRequestedStop = false
    var stderrTail = Data()

    init(rule: ForwardingRule, profileID: UUID, sessionID: UUID?, isIndependent: Bool) {
        id = rule.id
        self.rule = rule
        self.profileID = profileID
        self.sessionID = sessionID
        self.isIndependent = isIndependent
        destinationReachability = .initial(for: rule)
    }

    deinit {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        credentialBroker?.stop()
        preparedCommand?.configuration.cleanup()
    }
}

private final class ManagedTransfer {
    let id: UUID
    var task: TransferTask
    let sessionID: UUID
    var work: Task<Void, Never>?
    var process: Process?
    var preparedCommand: PreparedOpenSSHCommand?
    var credentialBroker: SessionCredentialBroker?
    var challengeGate: CredentialChallengeGate?
    var diagnostics = Data()
    /// This is deliberately scoped to the live queue item. A relaunched app
    /// cannot prove the old per-leaf conflict decisions, so it restarts a
    /// recursive task instead of appending to an inferred destination.
    var recursiveResumeLedger = RecursiveTransferResumeLedger()
    var skippedItemCount = 0

    init(task: TransferTask, sessionID: UUID) {
        id = task.id
        self.task = task
        self.sessionID = sessionID
    }

    deinit {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        credentialBroker?.stop()
        preparedCommand?.configuration.cleanup()
    }
}

private final class ManagedRemoteEdit {
    let id: UUID
    let sessionID: UUID
    let remotePath: String
    let localURL: URL
    var sourceFingerprint: RemoteEditSourceFingerprint

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        remotePath: String,
        localURL: URL,
        sourceFingerprint: RemoteEditSourceFingerprint
    ) {
        self.id = id
        self.sessionID = sessionID
        self.remotePath = remotePath
        self.localURL = localURL
        self.sourceFingerprint = sourceFingerprint
    }

    var presentation: RemoteEditPresentation {
        RemoteEditPresentation(
            id: id,
            sessionID: sessionID,
            remotePath: remotePath,
            localURL: localURL
        )
    }
}

private struct PendingSSHConfigImport {
    let result: SSHConfigImportResult
}

private struct RemoteEditSourceFingerprint: Equatable {
    var metadata: TransferSourceFingerprint
    var sha256: Data
}

private enum TransferFileIOError: Error {
    case closed
}

private enum TransferConflictOutcome: Error {
    case skipItem
}

/// File chunks are read and written on a non-main actor. Network work already
/// suspends through `SFTPClient`; this keeps local file I/O off the SwiftUI
/// executor too.
private actor TransferFileReader {
    private var handle: FileHandle?

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle?.close()
    }

    func seek(to offset: UInt64) throws {
        guard let handle else { throw TransferFileIOError.closed }
        try handle.seek(toOffset: offset)
    }

    func read(upToCount count: Int) throws -> Data {
        guard let handle else { throw TransferFileIOError.closed }
        return try handle.read(upToCount: count) ?? Data()
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

private actor TransferFileWriter {
    private var handle: FileHandle?

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle?.close()
    }

    func seek(to offset: UInt64) throws {
        guard let handle else { throw TransferFileIOError.closed }
        try handle.seek(toOffset: offset)
    }

    func write(_ data: Data) throws {
        guard let handle else { throw TransferFileIOError.closed }
        try handle.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

private final class ManagedSFTPConnection {
    let client: SFTPClient
    let transport: SFTPProcessTransport
    let credentialBroker: SessionCredentialBroker
    let challengeGate: CredentialChallengeGate
    var currentPath: String = "."
    var files: [RemoteFilePresentation] = []

    init(
        client: SFTPClient,
        transport: SFTPProcessTransport,
        credentialBroker: SessionCredentialBroker,
        challengeGate: CredentialChallengeGate
    ) {
        self.client = client
        self.transport = transport
        self.credentialBroker = credentialBroker
        self.challengeGate = challengeGate
    }

    deinit { credentialBroker.stop() }
}

@MainActor
final class CoreWorkspaceService: AppWorkspaceService {
    let isAvailable = true

    private let profileRepository: ProfileRepository
    private let workspaceRepository: WorkspaceRepository
    private let keychain = KeychainSecretStore()
    private let hostKeyStore: HostKeyStore
    private let knownHostsURL: URL
    private let storageDirectory: URL

    private var profileDocument = ProfileDocument()
    private var workspaceDocument = AppWorkspaceDocument()
    private var didLoad = false
    private var sessions: [UUID: ManagedTerminalSession] = [:]
    private var sessionOrder: [UUID] = []
    private var selectedSessionID: UUID?
    private var paneSessionIDs: [UUID] = []
    private var workspaceLayout: WorkspaceLayoutPresentation = .single
    private var transfers: [UUID: ManagedTransfer] = [:]
    private var remoteEdits: [UUID: ManagedRemoteEdit] = [:]
    private var tunnels: [UUID: ManagedTunnel] = [:]
    private var sftpConnections: [UUID: ManagedSFTPConnection] = [:]
    private var challengeGates: [UUID: CredentialChallengeGate] = [:]
    private var changedHostKeyChallenges: [UUID: UUID] = [:]
    private var newHostKeyFallbackChallenges: [UUID: UUID] = [:]
    private var pendingSSHConfigImports: [UUID: PendingSSHConfigImport] = [:]
    private var authenticationChallenge: AuthenticationChallengePresentation?
    private var snapshotHandler: (@MainActor (AppWorkspaceSnapshot) -> Void)?

    init() throws {
        profileRepository = try ProfileRepository()
        workspaceRepository = try WorkspaceRepository()
        storageDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProfileRepository.applicationName, isDirectory: true)
        knownHostsURL = storageDirectory.appendingPathComponent("known_hosts")
        hostKeyStore = try HostKeyStore(fileURL: knownHostsURL)
    }

    deinit {
        for session in sessions.values {
            session.userRequestedStop = true
            session.challengeGate?.cancelAll()
        }
        for tunnel in tunnels.values {
            tunnel.userRequestedStop = true
            tunnel.process?.terminate()
        }
    }

    func setSnapshotHandler(_ handler: @escaping @MainActor (AppWorkspaceSnapshot) -> Void) {
        snapshotHandler = handler
    }

    func loadSnapshot() async throws -> AppWorkspaceSnapshot {
        try await loadIfNeeded()
        return makeSnapshot()
    }

    func connect(profileID: UUID) async throws {
        try await loadIfNeeded()
        guard let profile = profileDocument.profiles.first(where: { $0.id == profileID }) else {
            throw CoreWorkspaceServiceError.profileNotFound
        }
        let descriptor = TerminalSessionDescriptor(
            title: nextSessionTitle(base: profile.name),
            kind: .profile(profile.id),
            shouldLog: workspaceDocument.settings.sessionLoggingEnabled
        )
        let session = ManagedTerminalSession(descriptor: descriptor, state: .connecting)
        sessions[session.id] = session
        sessionOrder.append(session.id)
        selectedSessionID = session.id
        setPaneSelectionAfterAdding(session.id)
        try await launchSSH(session: session, profile: profile, hostKeyPolicy: .promptUser)
        try await persistWorkspace()
        emitSnapshot()
    }

    func startLocalTerminal() async throws {
        try await loadIfNeeded()
        let descriptor = TerminalSessionDescriptor(
            title: nextSessionTitle(base: AppText.string("Local Shell", korean: "로컬 셸")),
            kind: .localShell,
            shouldLog: workspaceDocument.settings.sessionLoggingEnabled
        )
        let session = ManagedTerminalSession(descriptor: descriptor, state: .connecting)
        let shell = localShellPath()
        session.launch = TerminalProcessLaunchPresentation(
            launchID: UUID(),
            executable: shell,
            arguments: ["-l"],
            environment: terminalEnvironment(overrides: [:]),
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        sessions[session.id] = session
        sessionOrder.append(session.id)
        selectedSessionID = session.id
        setPaneSelectionAfterAdding(session.id)
        try await persistWorkspace()
        emitSnapshot()
    }

    func disconnect(sessionID: UUID) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID] else { throw CoreWorkspaceServiceError.sessionNotFound }
        broadcastTargetSessionIDs.remove(sessionID)
        session.userRequestedStop = true
        session.challengeGate?.cancelAll()
        session.launch = nil
        session.state = .disconnected
        session.credentialBroker?.stop()
        session.credentialBroker = nil
        session.preparedCommand?.configuration.cleanup()
        session.preparedCommand = nil
        if let connection = sftpConnections.removeValue(forKey: sessionID) {
            await connection.transport.close()
        }
        emitSnapshot()
    }

    func closeSession(id: UUID) async throws {
        try await loadIfNeeded()
        guard sessions[id] != nil else { throw CoreWorkspaceServiceError.sessionNotFound }
        try await disconnect(sessionID: id)
        for tunnel in tunnels.values where tunnel.sessionID == id && !tunnel.isIndependent {
            tunnel.userRequestedStop = true
            tunnel.process?.terminate()
            cleanTunnelResources(tunnel)
            tunnel.phase = .stopped
        }
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll(where: { $0 == id })
        paneSessionIDs.removeAll(where: { $0 == id })
        if selectedSessionID == id {
            selectedSessionID = sessionOrder.last
        }
        if workspaceLayout == .single {
            paneSessionIDs = selectedSessionID.map { [$0] } ?? []
        }
        try await persistWorkspace()
        emitSnapshot()
    }

    func selectSession(id: UUID?) async throws {
        try await loadIfNeeded()
        if let id, sessions[id] == nil { throw CoreWorkspaceServiceError.sessionNotFound }
        selectedSessionID = id
        if workspaceLayout == .single, let id { paneSessionIDs = [id] }
        try await persistWorkspace()
        emitSnapshot()
    }

    func setWorkspaceLayout(_ layout: WorkspaceLayoutPresentation) async throws {
        try await loadIfNeeded()
        workspaceLayout = layout
        let available = sessionOrder.filter { sessions[$0] != nil }
        switch layout {
        case .single:
            paneSessionIDs = selectedSessionID.map { [$0] } ?? Array(available.prefix(1))
        case .horizontalSplit, .verticalSplit:
            var selected = paneSessionIDs.filter { sessions[$0] != nil }
            if selected.isEmpty, let selectedSessionID { selected.append(selectedSessionID) }
            for id in available where selected.count < 2 && !selected.contains(id) { selected.append(id) }
            paneSessionIDs = Array(selected.prefix(2))
        }
        try await persistWorkspace()
        emitSnapshot()
    }

    func renameSession(id: UUID, title: String) async throws {
        try await loadIfNeeded()
        guard let session = sessions[id] else { throw CoreWorkspaceServiceError.sessionNotFound }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Enter a tab name up to 120 characters.",
                korean: "120자 이하의 탭 이름을 입력하세요."
            ))
        }
        session.descriptor.title = trimmed
        try await persistWorkspace()
        emitSnapshot()
    }

    func duplicateSession(id: UUID) async throws {
        try await loadIfNeeded()
        guard let session = sessions[id] else { throw CoreWorkspaceServiceError.sessionNotFound }
        switch session.descriptor.kind {
        case .localShell:
            try await startLocalTerminal()
        case let .profile(profileID):
            try await connect(profileID: profileID)
        }
    }

    private func nextSessionTitle(base: String) -> String {
        TerminalSessionTitleAllocator.nextTitle(
            base: base,
            existingTitles: sessions.values.map(\.descriptor.title)
        )
    }

    func moveSession(id: UUID, toIndex: Int) async throws {
        try await loadIfNeeded()
        guard let currentIndex = sessionOrder.firstIndex(of: id) else {
            throw CoreWorkspaceServiceError.sessionNotFound
        }
        let boundedIndex = min(max(0, toIndex), max(0, sessionOrder.count - 1))
        guard currentIndex != boundedIndex else { return }
        sessionOrder.remove(at: currentIndex)
        sessionOrder.insert(id, at: boundedIndex)
        try await persistWorkspace()
        emitSnapshot()
    }

    func profileDraft(for profileID: UUID) async throws -> ProfileDraftPresentation {
        try await loadIfNeeded()
        guard let profile = profileDocument.profiles.first(where: { $0.id == profileID }) else {
            throw CoreWorkspaceServiceError.profileNotFound
        }
        return profileDraft(from: profile)
    }

    func saveProfile(_ submission: ProfileEditorSubmission) async throws {
        try await loadIfNeeded()
        let prior = profileDocument.profiles.first(where: { $0.id == submission.draft.id })
        let profile = try makeProfile(from: submission, prior: prior)
        _ = try SSHRouteResolver.resolve(target: profile, profiles: profileDocument.profiles.filter { $0.id != profile.id } + [profile])
        try await profileRepository.save(profile)
        profileDocument = await profileRepository.snapshot()
        emitSnapshot()
    }

    func duplicateProfile(id: UUID) async throws {
        try await loadIfNeeded()
        guard var profile = profileDocument.profiles.first(where: { $0.id == id }) else {
            throw CoreWorkspaceServiceError.profileNotFound
        }
        profile.id = UUID()
        profile.name += AppText.string(" Copy", korean: " 복사본")
        profile.isFavorite = false
        profile.createdAt = .now
        profile.updatedAt = .now
        profile.authentication = duplicateAuthenticationReference(profile.authentication)
        if var proxy = profile.proxy { proxy.password = nil; profile.proxy = proxy }
        try await profileRepository.save(profile)
        profileDocument = await profileRepository.snapshot()
        emitSnapshot()
    }

    func deleteProfile(id: UUID) async throws {
        try await loadIfNeeded()
        guard !sessions.values.contains(where: { $0.profileID == id && $0.state.isActive }) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Disconnect active sessions before deleting this profile.",
                korean: "이 프로필을 삭제하기 전에 활성 세션을 연결 해제하세요."
            ))
        }
        guard let profile = profileDocument.profiles.first(where: { $0.id == id }) else {
            throw CoreWorkspaceServiceError.profileNotFound
        }
        let dependents = profileDocument.profiles.filter { $0.id != id && $0.jumpProfileIDs.contains(id) }
        guard dependents.isEmpty else {
            let names = dependents.map(\.name).sorted().joined(separator: ", ")
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "This profile is used as a jump host by \(names). Edit those routes before deleting it.",
                korean: "\(names)에서 이 프로필을 Jump host로 사용합니다. 해당 경로를 수정한 뒤 삭제하세요."
            ))
        }
        try await profileRepository.deleteProfile(id: id)
        deleteSecrets(referencedBy: profile)
        profileDocument = await profileRepository.snapshot()
        emitSnapshot()
    }

    func setFavorite(profileID: UUID, isFavorite: Bool) async throws {
        try await loadIfNeeded()
        guard var profile = profileDocument.profiles.first(where: { $0.id == profileID }) else {
            throw CoreWorkspaceServiceError.profileNotFound
        }
        profile.isFavorite = isFavorite
        try await profileRepository.save(profile)
        profileDocument = await profileRepository.snapshot()
        emitSnapshot()
    }

    func saveFolder(id: UUID?, name: String) async throws {
        try await loadIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Enter a folder name up to 120 characters.",
                korean: "120자 이하의 폴더 이름을 입력하세요."
            ))
        }
        guard !profileDocument.folders.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "A folder with that name already exists.",
                korean: "같은 이름의 폴더가 이미 있습니다."
            ))
        }
        let folder: ConnectionFolder
        if let id, let existing = profileDocument.folders.first(where: { $0.id == id }) {
            folder = ConnectionFolder(id: existing.id, name: trimmed, sortOrder: existing.sortOrder)
        } else {
            let nextOrder = (profileDocument.folders.map(\.sortOrder).max() ?? -1) + 1
            folder = ConnectionFolder(name: trimmed, sortOrder: nextOrder)
        }
        try await profileRepository.saveFolder(folder)
        profileDocument = await profileRepository.snapshot()
        emitSnapshot()
    }

    func deleteFolder(id: UUID) async throws {
        try await loadIfNeeded()
        guard profileDocument.folders.contains(where: { $0.id == id }) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The selected folder no longer exists.",
                korean: "선택한 폴더가 더 이상 없습니다."
            ))
        }
        try await profileRepository.deleteFolder(id: id)
        profileDocument = await profileRepository.snapshot()
        emitSnapshot()
    }

    func previewSSHConfig(from url: URL) async throws -> SSHConfigImportPreviewPresentation {
        try await loadIfNeeded()
        let result = try SSHConfigImporter().import(from: url)
        let preview = sshConfigImportPreview(result: result, sourceURL: url)
        pendingSSHConfigImports[preview.id] = PendingSSHConfigImport(result: result)
        return preview
    }

    func importSSHConfig(previewID: UUID, profileIDs: Set<UUID>) async throws {
        try await loadIfNeeded()
        guard let pending = pendingSSHConfigImports[previewID] else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "This SSH config preview is no longer available. Preview the file again.",
                korean: "이 SSH 설정 미리보기를 더 이상 사용할 수 없습니다. 파일을 다시 미리보세요."
            ))
        }
        let profiles: [ConnectionProfile]
        do {
            profiles = try pending.result.connectionProfiles(selectedIDs: profileIDs)
        } catch SSHConfigImportSelectionError.emptySelection {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Select at least one profile to import.",
                korean: "가져올 프로필을 하나 이상 선택하세요."
            ))
        } catch SSHConfigImportSelectionError.unknownProfileIDs {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The selected SSH config profiles changed. Preview the file again.",
                korean: "선택한 SSH 설정 프로필이 변경되었습니다. 파일을 다시 미리보세요."
            ))
        } catch let SSHConfigImportSelectionError.missingJumpProfileReferences(ids) {
            let names = pending.result.profiles
                .filter { ids.contains($0.id) }
                .map(\.alias)
                .sorted()
                .joined(separator: ", ")
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Select every referenced jump profile before importing: \(names).",
                korean: "참조된 Jump host 프로필을 모두 선택하세요: \(names)."
            ))
        }
        for profile in profiles {
            try await profileRepository.save(profile)
        }
        pendingSSHConfigImports.removeValue(forKey: previewID)
        profileDocument = await profileRepository.snapshot()
        emitSnapshot()
    }

    func discardSSHConfigImportPreview(id: UUID) async {
        pendingSSHConfigImports.removeValue(forKey: id)
    }

    func exportProfiles(ids: [UUID], to url: URL) async throws {
        try await loadIfNeeded()
        let selected = profileDocument.profiles.filter { ids.contains($0.id) }
        let data = try JSONEncoder.osXtermExport.encode(ProfileExportDocument(profiles: selected))
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func exportSessionLog(sessionID: UUID, to url: URL) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID] else {
            throw CoreWorkspaceServiceError.sessionNotFound
        }

        do {
            try session.logFile?.synchronize()
        } catch {
            throw CoreWorkspaceServiceError.sessionLogExportFailed
        }

        let sourceURL = sessionLogURL(for: session.id)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CoreWorkspaceServiceError.sessionLogUnavailable
        }
        do {
            try await SecureFileExporter.exportFile(from: sourceURL, to: url)
        } catch SecureFileExporterError.sourceDoesNotExist {
            throw CoreWorkspaceServiceError.sessionLogUnavailable
        } catch {
            throw CoreWorkspaceServiceError.sessionLogExportFailed
        }
    }

    func enqueueUpload(
        urls: [URL],
        to sessionID: UUID,
        conflictPolicy: TransferConflictPolicy
    ) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID],
              let profileID = session.profileID,
              session.state.isInputReady
        else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        let connection = try await sftpConnection(for: session)
        let remoteBase = connection.currentPath
        for localURL in urls {
            let remotePath = joinRemotePath(remoteBase, localURL.lastPathComponent)
            let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let task = TransferTask(
                profileID: profileID,
                direction: .upload,
                localURL: localURL,
                remotePath: remotePath,
                isRecursive: values.isDirectory == true,
                conflictPolicy: conflictPolicy,
                totalBytes: values.fileSize.map(Int64.init)
            )
            let managed = ManagedTransfer(task: task, sessionID: sessionID)
            transfers[managed.id] = managed
            beginTransfer(managed)
        }
        emitSnapshot()
    }

    func enqueueSCPUpload(
        urls: [URL],
        to sessionID: UUID,
        conflictPolicy: TransferConflictPolicy
    ) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID],
              let profileID = session.profileID,
              session.state.isInputReady
        else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }

        // The current SFTP directory is the visible destination. Resolving it
        // through the existing SFTP connection avoids a second, UI-specific
        // path convention for SCP uploads.
        let connection = try await sftpConnection(for: session)
        let remoteBase = connection.currentPath
        for localURL in urls {
            let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let task = TransferTask(
                profileID: profileID,
                direction: .scpUpload,
                localURL: localURL,
                remotePath: joinRemotePath(remoteBase, localURL.lastPathComponent),
                isRecursive: values.isDirectory == true,
                conflictPolicy: conflictPolicy,
                totalBytes: values.fileSize.map(Int64.init)
            )
            let managed = ManagedTransfer(task: task, sessionID: sessionID)
            transfers[managed.id] = managed
            beginTransfer(managed)
        }
        emitSnapshot()
    }

    func enqueueDownload(
        transferID: UUID,
        to url: URL,
        conflictPolicy: TransferConflictPolicy
    ) async throws {
        try await loadIfNeeded()
        guard let existing = transfers[transferID] else { throw CoreWorkspaceServiceError.transferNotFound }
        guard let session = sessions[existing.sessionID], session.state.isInputReady else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        let task = TransferTask(
            profileID: existing.task.profileID,
            direction: .download,
            localURL: url,
            remotePath: existing.task.remotePath,
            isRecursive: existing.task.isRecursive,
            conflictPolicy: conflictPolicy
        )
        let managed = ManagedTransfer(task: task, sessionID: session.id)
        transfers[managed.id] = managed
        beginTransfer(managed)
        emitSnapshot()
    }

    func refreshRemoteFiles(sessionID: UUID) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], session.state.isInputReady else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        let connection = try await sftpConnection(for: session)
        try await refreshRemoteFiles(connection)
        emitSnapshot()
    }

    func navigateRemoteDirectory(path: String, sessionID: UUID) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], session.state.isInputReady else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        let connection = try await sftpConnection(for: session)
        let resolved = try SFTPRemotePath(rawValue: path)
        _ = try await connection.client.openDirectory(resolved)
        connection.currentPath = path
        try await refreshRemoteFiles(connection)
        emitSnapshot()
    }

    func createRemoteDirectory(name: String, sessionID: UUID) async throws {
        try await loadIfNeeded()
        let connection = try await requireReadySFTP(sessionID: sessionID)
        let path = try SFTPRemotePath(rawValue: joinRemotePath(connection.currentPath, try safeRemoteName(name)))
        try await connection.client.makeDirectory(path)
        try await refreshRemoteFiles(connection)
        emitSnapshot()
    }

    func renameRemoteFile(path: String, to name: String, sessionID: UUID) async throws {
        try await loadIfNeeded()
        let connection = try await requireReadySFTP(sessionID: sessionID)
        let from = try SFTPRemotePath(rawValue: path)
        let destination = try SFTPRemotePath(rawValue: joinRemotePath(remoteParent(path), try safeRemoteName(name)))
        try await connection.client.rename(from: from, to: destination)
        try await refreshRemoteFiles(connection)
        emitSnapshot()
    }

    func deleteRemoteFile(path: String, sessionID: UUID) async throws {
        try await loadIfNeeded()
        let connection = try await requireReadySFTP(sessionID: sessionID)
        let remotePath = try SFTPRemotePath(rawValue: path)
        let attributes = try await connection.client.attributes(of: remotePath, followSymlink: false)
        if isRemoteDirectory(attributes) {
            try await removeRemoteDirectoryRecursively(remotePath, client: connection.client)
        } else {
            try await connection.client.remove(remotePath)
        }
        try await refreshRemoteFiles(connection)
        emitSnapshot()
    }

    func changeRemotePermissions(path: String, permissions: String, sessionID: UUID) async throws {
        try await loadIfNeeded()
        let connection = try await requireReadySFTP(sessionID: sessionID)
        guard let parsed = UInt32(permissions, radix: 8), parsed <= 0o7777 else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Permissions must be an octal value such as 0644.",
                korean: "권한은 0644 같은 8진수 값이어야 합니다."
            ))
        }
        let remotePath = try SFTPRemotePath(rawValue: path)
        let prior = try await connection.client.attributes(of: remotePath, followSymlink: false)
        let typeBits = (prior.permissions ?? 0) & 0o170000
        try await connection.client.setAttributes(
            SFTPFileAttributes(permissions: typeBits | parsed),
            for: remotePath
        )
        try await refreshRemoteFiles(connection)
        emitSnapshot()
    }

    func downloadRemoteFile(
        path: String,
        to url: URL,
        sessionID: UUID,
        conflictPolicy: TransferConflictPolicy
    ) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], let profileID = session.profileID else {
            throw CoreWorkspaceServiceError.sessionNotFound
        }
        let remotePath = try SFTPRemotePath(rawValue: path)
        let attributes = try await (try await requireReadySFTP(sessionID: sessionID)).client.attributes(of: remotePath)
        let task = TransferTask(
            profileID: profileID,
            direction: .download,
            localURL: url,
            remotePath: path,
            isRecursive: isRemoteDirectory(attributes),
            conflictPolicy: conflictPolicy,
            totalBytes: attributes.size.flatMap(Int64.init)
        )
        let managed = ManagedTransfer(task: task, sessionID: sessionID)
        transfers[managed.id] = managed
        beginTransfer(managed)
        emitSnapshot()
    }

    func downloadRemoteFileViaSCP(
        path: String,
        to url: URL,
        sessionID: UUID,
        conflictPolicy: TransferConflictPolicy
    ) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], let profileID = session.profileID else {
            throw CoreWorkspaceServiceError.sessionNotFound
        }
        let remotePath = try SFTPRemotePath(rawValue: path)
        let attributes = try await (try await requireReadySFTP(sessionID: sessionID)).client.attributes(of: remotePath)
        let task = TransferTask(
            profileID: profileID,
            direction: .scpDownload,
            localURL: url,
            remotePath: path,
            isRecursive: isRemoteDirectory(attributes),
            conflictPolicy: conflictPolicy,
            totalBytes: attributes.size.flatMap(Int64.init)
        )
        let managed = ManagedTransfer(task: task, sessionID: sessionID)
        transfers[managed.id] = managed
        beginTransfer(managed)
        emitSnapshot()
    }

    func openRemoteFileForEditing(path: String, sessionID: UUID) async throws -> RemoteEditPresentation {
        try await loadIfNeeded()
        if let existing = remoteEdits.values.first(where: { $0.sessionID == sessionID && $0.remotePath == path }) {
            return existing.presentation
        }
        let connection = try await requireReadySFTP(sessionID: sessionID)
        let remotePath = try SFTPRemotePath(rawValue: path)
        let sourceBeforeDownload = try await remoteTransferFingerprint(at: remotePath, client: connection.client)
        let localURL = try makeRemoteEditURL(for: remotePath)
        let remoteHandle = try await connection.client.open(path: remotePath, flags: [.read])

        let manager = FileManager.default
        let localHandle: TransferFileWriter
        do {
            guard manager.createFile(atPath: localURL.path, contents: nil) else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "Could not create the local editing copy.",
                    korean: "로컬 편집 사본을 만들 수 없습니다."
                ))
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localURL.path)
            localHandle = try TransferFileWriter(url: localURL)
        } catch {
            try? await connection.client.close(remoteHandle)
            try? manager.removeItem(at: localURL)
            throw error
        }

        do {
            var offset: UInt64 = 0
            var hasher = SHA256()
            while let chunk = try await connection.client.read(from: remoteHandle, offset: offset, length: 64 * 1024) {
                try Task.checkCancellation()
                try await localHandle.write(chunk)
                hasher.update(data: chunk)
                offset += UInt64(chunk.count)
            }
            try await connection.client.close(remoteHandle)
            await localHandle.close()
            let sourceAfterDownload = try await remoteTransferFingerprint(at: remotePath, client: connection.client)
            guard sourceAfterDownload == sourceBeforeDownload else {
                try? manager.removeItem(at: localURL)
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "The remote file changed while the editing copy was downloading. Open it again to get a consistent copy.",
                    korean: "편집 사본을 다운로드하는 동안 원격 파일이 변경되었습니다. 일관된 사본을 위해 다시 여세요."
                ))
            }
            let edit = ManagedRemoteEdit(
                sessionID: sessionID,
                remotePath: remotePath.rawValue,
                localURL: localURL,
                sourceFingerprint: RemoteEditSourceFingerprint(
                    metadata: sourceAfterDownload,
                    sha256: Data(hasher.finalize())
                )
            )
            remoteEdits[edit.id] = edit
            emitSnapshot()
            return edit.presentation
        } catch {
            try? await connection.client.close(remoteHandle)
            await localHandle.close()
            try? manager.removeItem(at: localURL)
            throw error
        }
    }

    func saveEditedRemoteFile(id: UUID) async throws {
        try await loadIfNeeded()
        guard let edit = remoteEdits[id] else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The local editing copy no longer exists.",
                korean: "로컬 편집 사본이 더 이상 없습니다."
            ))
        }
        let connection = try await requireReadySFTP(sessionID: edit.sessionID)
        let remotePath = try SFTPRemotePath(rawValue: edit.remotePath)
        let currentSource = try await remoteEditFingerprint(at: remotePath, client: connection.client)
        guard currentSource == edit.sourceFingerprint else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The remote file changed after this working copy was opened. Refresh or save a new copy before overwriting it.",
                korean: "작업 사본을 연 뒤 원격 파일이 변경되었습니다. 덮어쓰기 전에 새 사본을 열거나 내용을 다시 확인하세요."
            ))
        }
        let remoteHandle = try await connection.client.open(
            path: remotePath,
            flags: [.write, .create, .truncate],
            attributes: SFTPFileAttributes(permissions: 0o100644)
        )
        let input: TransferFileReader
        do {
            _ = try localTransferFingerprint(at: edit.localURL)
            input = try TransferFileReader(url: edit.localURL)
        } catch {
            try? await connection.client.close(remoteHandle)
            throw error
        }

        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await input.read(upToCount: 64 * 1024)
                if chunk.isEmpty { break }
                try await connection.client.write(chunk, to: remoteHandle, offset: offset)
                offset += UInt64(chunk.count)
            }
            try await connection.client.close(remoteHandle)
            await input.close()
        } catch {
            try? await connection.client.close(remoteHandle)
            await input.close()
            throw error
        }
        edit.sourceFingerprint = try await remoteEditFingerprint(at: remotePath, client: connection.client)
        try await refreshRemoteFiles(connection)
        emitSnapshot()
    }

    func discardEditedRemoteFile(id: UUID) async throws {
        try await loadIfNeeded()
        guard let edit = remoteEdits.removeValue(forKey: id) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The local editing copy no longer exists.",
                korean: "로컬 편집 사본이 더 이상 없습니다."
            ))
        }
        try? FileManager.default.removeItem(at: edit.localURL)
        emitSnapshot()
    }

    func cancelTransfer(id: UUID) async throws {
        try await loadIfNeeded()
        guard let transfer = transfers[id] else { throw CoreWorkspaceServiceError.transferNotFound }
        transfer.work?.cancel()
        transfer.process?.terminate()
        if transfer.task.state == .queued || transfer.task.state == .preparing || transfer.task.state == .running || transfer.task.state == .paused {
            transfer.task = try TransferTaskStateMachine.apply(.requestCancellation, to: transfer.task)
        }
        emitSnapshot()
    }

    func retryTransfer(id: UUID) async throws {
        try await loadIfNeeded()
        guard let transfer = transfers[id] else { throw CoreWorkspaceServiceError.transferNotFound }
        transfer.task = try TransferTaskStateMachine.apply(.retry, to: transfer.task)
        beginTransfer(transfer)
        emitSnapshot()
    }

    func startTunnel(id: UUID) async throws {
        try await loadIfNeeded()
        guard let tunnel = tunnels[id] else { throw CoreWorkspaceServiceError.tunnelNotFound }
        guard tunnel.process?.isRunning != true else { return }
        guard let profile = profileDocument.profiles.first(where: { $0.id == tunnel.profileID }) else {
            throw CoreWorkspaceServiceError.profileNotFound
        }
        try await launchTunnel(tunnel, profile: profile)
        emitSnapshot()
    }

    func stopTunnel(id: UUID) async throws {
        try await loadIfNeeded()
        guard let tunnel = tunnels[id] else { throw CoreWorkspaceServiceError.tunnelNotFound }
        tunnel.userRequestedStop = true
        tunnel.phase = .stopping
        tunnel.process?.terminate()
        if tunnel.process?.isRunning != true {
            cleanTunnelResources(tunnel)
            tunnel.phase = .stopped
            tunnel.destinationReachability = .initial(for: tunnel.rule)
        }
        emitSnapshot()
    }

    func restartTunnel(id: UUID) async throws {
        try await stopTunnel(id: id)
        try await startTunnel(id: id)
    }

    func probeTunnelDestination(id: UUID) async throws {
        try await loadIfNeeded()
        guard let tunnel = tunnels[id] else { throw CoreWorkspaceServiceError.tunnelNotFound }
        guard tunnel.phase == .listening else {
            throw CoreWorkspaceServiceError.invalidForwarding(AppText.string(
                "Start the tunnel and wait for its listener before testing the destination.",
                korean: "터널을 시작하고 listener가 준비된 뒤에 대상을 확인하세요."
            ))
        }
        guard let target = TunnelDestinationProbe.target(
            for: tunnel.rule,
            assignedPort: tunnel.assignedPort
        ) else {
            tunnel.destinationReachability = .notApplicable
            emitSnapshot()
            return
        }

        tunnel.destinationReachability = .probing
        emitSnapshot()
        let result = await TunnelDestinationProbe.probe(target)
        guard let current = tunnels[id], current === tunnel,
              current.phase == .listening,
              current.process?.isRunning == true
        else {
            return
        }

        switch result {
        case .reachable:
            current.destinationReachability = .reachable
        case let .unreachable(failure):
            current.destinationReachability = .unreachable(message: destinationProbeMessage(for: failure))
        }
        emitSnapshot()
    }

    func saveTunnel(_ draft: ForwardingDraftPresentation, sessionID: UUID?) async throws {
        try await loadIfNeeded()
        guard let sessionID,
              let session = sessions[sessionID],
              let profileID = session.profileID,
              var profile = profileDocument.profiles.first(where: { $0.id == profileID })
        else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        let rule = try forwardingRule(from: draft)
        if let old = tunnels[rule.id] {
            old.userRequestedStop = true
            old.process?.terminate()
            tunnels.removeValue(forKey: rule.id)
        }
        if let index = profile.forwardingRules.firstIndex(where: { $0.id == rule.id }) {
            profile.forwardingRules[index] = rule
        } else {
            profile.forwardingRules.append(rule)
        }
        try await profileRepository.save(profile)
        profileDocument = await profileRepository.snapshot()
        let tunnel = ManagedTunnel(rule: rule, profileID: profileID, sessionID: sessionID, isIndependent: draft.startIndependently)
        tunnels[rule.id] = tunnel
        if draft.startIndependently || session.state.isInputReady {
            try await launchTunnel(tunnel, profile: profile)
        }
        emitSnapshot()
    }

    func deleteTunnel(id: UUID) async throws {
        try await loadIfNeeded()
        guard let tunnel = tunnels.removeValue(forKey: id) else { throw CoreWorkspaceServiceError.tunnelNotFound }
        tunnel.userRequestedStop = true
        tunnel.process?.terminate()
        cleanTunnelResources(tunnel)
        if var profile = profileDocument.profiles.first(where: { $0.id == tunnel.profileID }) {
            profile.forwardingRules.removeAll(where: { $0.id == id })
            try await profileRepository.save(profile)
            profileDocument = await profileRepository.snapshot()
        }
        emitSnapshot()
    }

    func runSnippet(id: UUID, on sessionIDs: Set<UUID>, values: [UUID: String]) async throws {
        try await loadIfNeeded()
        guard let snippet = workspaceDocument.snippets.first(where: { $0.id == id }) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string("The snippet no longer exists.", korean: "스니펫이 더 이상 없습니다."))
        }
        guard !sessionIDs.isEmpty else { return }
        for sessionID in sessionIDs {
            guard let session = sessions[sessionID], session.state.isInputReady else {
                throw CoreWorkspaceServiceError.sessionNotReady
            }
            guard session.launch != nil else { throw CoreWorkspaceServiceError.sessionNotReady }
        }
        let variableIDs = Set(snippet.variables.map(\.id))
        guard Set(values.keys) == variableIDs else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Enter a value for every snippet variable.",
                korean: "모든 스니펫 변수 값을 입력하세요."
            ))
        }
        var commandText = snippet.commands
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        for variable in snippet.variables {
            let name = variable.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeSnippetVariableName(name),
                  let value = values[variable.id],
                  !value.unicodeScalars.contains(where: { $0.value == 0 }),
                  !value.contains("\n"), !value.contains("\r")
            else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "Snippet values must be single-line text and variable names must be letters, numbers, or underscores.",
                    korean: "스니펫 값은 한 줄 텍스트여야 하며 변수 이름에는 문자, 숫자, 밑줄만 사용할 수 있습니다."
                ))
            }
            commandText = commandText.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        guard !commandText.isEmpty else { return }
        let input = Data((commandText + "\n").utf8)
        for sessionID in sessionIDs {
            if let session = sessions[sessionID] {
                appendTerminalInputLog(input, kind: "snippet input", to: session)
            }
            enqueueTerminalInput(input, to: sessionID)
        }
        emitSnapshot()
    }

    func saveSnippet(title: String, commandsText: String) async throws {
        try await loadIfNeeded()
        let components = try snippetComponents(title: title, commandsText: commandsText)
        var snippets = workspaceDocument.snippets
        snippets.append(CommandSnippet(title: components.title, commands: components.commands, variables: components.variables))
        try await workspaceRepository.replaceSnippets(snippets)
        workspaceDocument = await workspaceRepository.snapshot()
        emitSnapshot()
    }

    func updateSnippet(id: UUID, title: String, commandsText: String) async throws {
        try await loadIfNeeded()
        let components = try snippetComponents(title: title, commandsText: commandsText)
        var snippets = workspaceDocument.snippets
        guard let index = snippets.firstIndex(where: { $0.id == id }) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The selected snippet no longer exists.",
                korean: "선택한 스니펫이 더 이상 없습니다."
            ))
        }
        snippets[index] = CommandSnippet(
            id: snippets[index].id,
            title: components.title,
            commands: components.commands,
            variables: components.variables
        )
        try await workspaceRepository.replaceSnippets(snippets)
        workspaceDocument = await workspaceRepository.snapshot()
        emitSnapshot()
    }

    func deleteSnippet(id: UUID) async throws {
        try await loadIfNeeded()
        var snippets = workspaceDocument.snippets
        let originalCount = snippets.count
        snippets.removeAll(where: { $0.id == id })
        guard snippets.count != originalCount else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The selected snippet no longer exists.",
                korean: "선택한 스니펫이 더 이상 없습니다."
            ))
        }
        try await workspaceRepository.replaceSnippets(snippets)
        workspaceDocument = await workspaceRepository.snapshot()
        emitSnapshot()
    }

    func setBroadcastTargets(_ sessionIDs: Set<UUID>) async throws {
        try await loadIfNeeded()
        guard sessionIDs.allSatisfy({ sessions[$0]?.state.isInputReady == true }) else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        broadcastTargetSessionIDs = sessionIDs
        emitSnapshot()
    }

    func terminalProcessDidStart(sessionID: UUID, launchID: UUID) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], session.launch?.launchID == launchID else { return }
        if session.isLocal {
            session.state = .connected
        } else {
            session.state = .authenticating(AppText.string("Verifying host key", korean: "호스트 키 확인 중"))
        }
        emitSnapshot()
    }

    func terminalProcessDidTerminate(sessionID: UUID, launchID: UUID, exitCode: Int32?) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], session.launch?.launchID == launchID else { return }
        broadcastTargetSessionIDs.remove(sessionID)
        let wasConnected = session.state == .connected
        let profile = session.profileID.flatMap { id in profileDocument.profiles.first(where: { $0.id == id }) }
        session.launch = nil
        session.credentialBroker?.stop()
        session.credentialBroker = nil
        session.preparedCommand?.configuration.cleanup()
        session.preparedCommand = nil
        session.challengeGate?.cancelAll()
        session.challengeGate = nil

        guard !session.userRequestedStop,
              let profile,
              wasConnected,
              let plan = SSHReconnectPolicy.nextPlan(
                after: .processExit(code: exitCode ?? -1),
                completedAttempts: session.reconnectAttempts,
                options: profile.options
              )
        else {
            if !session.userRequestedStop && !session.isLocal && !isTerminalFailure(session.state) {
                session.state = .disconnected
            }
            emitSnapshot()
            return
        }

        session.reconnectAttempts = plan.attempt
        session.state = .reconnecting(attempt: plan.attempt)
        emitSnapshot()
        Task { [weak self, weak session] in
            let nanoseconds = UInt64(plan.delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, let session, !session.userRequestedStop else { return }
            do {
                try await self.launchSSH(session: session, profile: profile, hostKeyPolicy: .promptUser)
                self.emitSnapshot()
            } catch {
                session.state = .failed(error.localizedDescription)
                self.emitSnapshot()
            }
        }
    }

    func terminalProcessDidOutput(sessionID: UUID, launchID: UUID, data: Data) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], session.launch?.launchID == launchID else { return }
        appendOutput(data, to: session)
        for event in OpenSSHOutputParser.events(in: String(decoding: data, as: UTF8.self)) {
            switch event {
            case .authenticated:
                guard !session.isLocal else { continue }
                session.state = .connected
                session.reconnectAttempts = 0
                if let profileID = session.profileID {
                    recentConnectionDates[profileID] = .now
                    try? await workspaceRepository.noteRecentProfile(profileID)
                    workspaceDocument = await workspaceRepository.snapshot()
                }
                Task { [hostKeyStore] in try? await hostKeyStore.reload() }
            case .authenticationFailed:
                session.state = .failed(AppText.string("Authentication failed.", korean: "인증에 실패했습니다."))
            case .hostKeyChanged:
                presentChangedHostKeyChallenge(for: session)
            case .hostKeyRejected:
                presentNewHostKeyFallbackChallenge(for: session)
            case let .transportFailure(message):
                session.state = .failed(message)
            }
        }
        if !session.state.isInputReady {
            broadcastTargetSessionIDs.remove(sessionID)
        }
        emitSnapshot()
    }

    func terminalInputDidSend(_ data: Data, from sessionID: UUID) async throws {
        try await loadIfNeeded()
        guard let session = sessions[sessionID], session.state.isInputReady else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        appendTerminalInputLog(data, kind: "input", to: session)
        let readySessionIDs = Set(sessions.compactMap { id, candidate in
            candidate.state.isInputReady ? id : nil
        })
        let activeBroadcastSessionIDs = BroadcastInputRouter.activeSessionIDs(
            selectedSessionIDs: broadcastTargetSessionIDs,
            readySessionIDs: readySessionIDs
        )
        let didPruneBroadcastTargets = activeBroadcastSessionIDs != broadcastTargetSessionIDs
        broadcastTargetSessionIDs = activeBroadcastSessionIDs
        let recipients = BroadcastInputRouter.recipients(
            sourceID: sessionID,
            selectedSessionIDs: activeBroadcastSessionIDs,
            readySessionIDs: readySessionIDs
        )
        for targetID in recipients {
            if let targetSession = sessions[targetID] {
                appendTerminalInputLog(data, kind: "broadcast input", to: targetSession)
            }
            enqueueTerminalInput(data, to: targetID)
        }
        if didPruneBroadcastTargets || !recipients.isEmpty {
            emitSnapshot()
        }
    }

    func terminalDidResize(sessionID: UUID, columns: Int, rows: Int) async throws {
        try await loadIfNeeded()
        guard sessions[sessionID] != nil, columns > 0, rows > 0 else {
            throw CoreWorkspaceServiceError.sessionNotFound
        }
    }

    func updateSettings(_ settings: AppSettingsPresentation) async throws {
        try await loadIfNeeded()
        let core = appSettings(from: settings)
        guard (6 ... 72).contains(core.terminalFontSize), (0.5 ... 3).contains(core.terminalLineSpacing) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string("Terminal settings are out of range.", korean: "터미널 설정 값이 허용 범위를 벗어났습니다."))
        }
        workspaceDocument.settings = core
        try await workspaceRepository.updateSettings(core)
        var didUpdateSessionLogging = false
        for session in sessions.values where session.descriptor.shouldLog != core.sessionLoggingEnabled {
            session.descriptor.shouldLog = core.sessionLoggingEnabled
            didUpdateSessionLogging = true
            if !core.sessionLoggingEnabled {
                try? session.logFile?.synchronize()
                try? session.logFile?.close()
                session.logFile = nil
            }
        }
        if didUpdateSessionLogging {
            try await persistWorkspace()
        }
        emitSnapshot()
    }

    func respond(to challengeID: UUID, response: String?) async throws {
        try await loadIfNeeded()
        if let gate = challengeGates[challengeID], gate.resolve(challengeID: challengeID, response: response) {
            challengeGates.removeValue(forKey: challengeID)
            if authenticationChallenge?.id == challengeID { authenticationChallenge = nil }
            emitSnapshot()
            return
        }
        if let sessionID = changedHostKeyChallenges.removeValue(forKey: challengeID),
           let session = sessions[sessionID],
           let route = session.route {
            if authenticationChallenge?.id == challengeID { authenticationChallenge = nil }
            guard response == "trust-changed-host-key" else {
                session.state = .failed(AppText.string("Host key change was not approved.", korean: "호스트 키 변경을 승인하지 않았습니다."))
                emitSnapshot()
                return
            }
            let endpoint = try SSHHostKeyEndpoint(host: route.target.host, port: route.target.port)
            try await hostKeyStore.remove(endpoint: endpoint)
            guard let profile = profileDocument.profiles.first(where: { $0.id == route.target.id }) else {
                throw CoreWorkspaceServiceError.profileNotFound
            }
            try await launchSSH(session: session, profile: profile, hostKeyPolicy: .promptUser)
            emitSnapshot()
            return
        }
        if let sessionID = newHostKeyFallbackChallenges.removeValue(forKey: challengeID),
           let session = sessions[sessionID],
           let route = session.route {
            if authenticationChallenge?.id == challengeID { authenticationChallenge = nil }
            guard response == "trust-new-host-key" else {
                session.state = .failed(AppText.string("Host key was not approved.", korean: "호스트 키를 승인하지 않았습니다."))
                emitSnapshot()
                return
            }
            guard let profile = profileDocument.profiles.first(where: { $0.id == route.target.id }) else {
                throw CoreWorkspaceServiceError.profileNotFound
            }
            try await launchSSH(session: session, profile: profile, hostKeyPolicy: .promptUser)
            emitSnapshot()
            return
        }
        throw CoreWorkspaceServiceError.invalidProfile(AppText.string("This authentication request has expired.", korean: "이 인증 요청은 만료되었습니다."))
    }

    func shutdown() {
        for transfer in transfers.values {
            transfer.work?.cancel()
            transfer.process?.terminate()
            transfer.challengeGate?.cancelAll()
        }
        for session in sessions.values {
            session.userRequestedStop = true
            session.challengeGate?.cancelAll()
            session.launch = nil
            session.credentialBroker?.stop()
            session.preparedCommand?.configuration.cleanup()
        }
        for connection in sftpConnections.values {
            Task { await connection.transport.close() }
        }
        sftpConnections.removeAll()
        for tunnel in tunnels.values {
            tunnel.userRequestedStop = true
            tunnel.process?.terminate()
            cleanTunnelResources(tunnel)
            tunnel.phase = .stopped
        }
        authenticationChallenge = nil
        challengeGates.removeAll()
        emitSnapshot()
    }

    // MARK: Workspace state and presentation

    private var broadcastTargetSessionIDs = Set<UUID>()
    private var recentConnectionDates: [UUID: Date] = [:]

    private func loadIfNeeded() async throws {
        guard !didLoad else { return }
        profileDocument = await profileRepository.snapshot()
        workspaceDocument = await workspaceRepository.snapshot()
        workspaceLayout = presentationLayout(from: workspaceDocument.workspace.layout)
        selectedSessionID = workspaceDocument.workspace.selectedSessionID

        for descriptor in workspaceDocument.workspace.sessions {
            if case let .profile(profileID) = descriptor.kind,
               !profileDocument.profiles.contains(where: { $0.id == profileID }) {
                continue
            }
            let restored = ManagedTerminalSession(descriptor: descriptor)
            sessions[restored.id] = restored
            sessionOrder.append(restored.id)
        }
        if let selectedSessionID, sessions[selectedSessionID] == nil {
            self.selectedSessionID = sessionOrder.first
        }
        let leaves = layoutSessionIDs(in: workspaceDocument.workspace.layout)
        paneSessionIDs = leaves.filter { sessions[$0] != nil }
        if paneSessionIDs.isEmpty, let selectedSessionID { paneSessionIDs = [selectedSessionID] }

        // Saved forwarding rules are restored as stopped definitions only. A
        // workspace restore never reconnects an SSH shell or starts a tunnel.
        for profile in profileDocument.profiles {
            for rule in profile.forwardingRules where tunnels[rule.id] == nil {
                tunnels[rule.id] = ManagedTunnel(
                    rule: rule,
                    profileID: profile.id,
                    sessionID: nil,
                    isIndependent: false
                )
            }
        }
        didLoad = true
    }

    private func makeSnapshot() -> AppWorkspaceSnapshot {
        let profiles = profileDocument.profiles
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { profile in
                let active = sessions.values
                    .filter { $0.profileID == profile.id }
                    .sorted { sessionOrder.firstIndex(of: $0.id) ?? 0 < sessionOrder.firstIndex(of: $1.id) ?? 0 }
                    .first
                return ProfilePresentation(
                    id: profile.id,
                    name: profile.name,
                    host: profile.host,
                    username: profile.username,
                    port: profile.port,
                    folderID: profile.folderID,
                    tags: profile.tags,
                    isFavorite: profile.isFavorite,
                    lastConnectedAt: recentConnectionDates[profile.id]
                        ?? workspaceDocument.recentProfileIDs.firstIndex(of: profile.id).map {
                            Date(timeIntervalSince1970: TimeInterval(workspaceDocument.recentProfileIDs.count - $0))
                        },
                    activeSessionState: active.map(\.state),
                    jumpHostCount: profile.jumpProfileIDs.count,
                    proxySummary: profile.proxy.map { proxy in
                        "\(proxy.kind == .httpConnect ? "HTTP CONNECT" : "SOCKS5") \(proxy.host):\(proxy.port)"
                    }
                )
            }
        let folders = profileDocument.folders
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
            .map { folder in
                FolderPresentation(
                    id: folder.id,
                    name: folder.name,
                    profileIDs: profileDocument.profiles.filter { $0.folderID == folder.id }.map(\.id)
                )
            }
        let terminalSessions = sessionOrder.compactMap { id in sessions[id].map(presentation(for:)) }
        let selectedSFTP = selectedSessionID.flatMap { sftpConnections[$0] }
        return AppWorkspaceSnapshot(
            profiles: profiles,
            folders: folders,
            sessions: terminalSessions,
            selectedSessionID: selectedSessionID,
            paneSessionIDs: paneSessionIDs,
            layout: workspaceLayout,
            transfers: transfers.values
                .sorted { $0.task.createdAt < $1.task.createdAt }
                .map(transferPresentation),
            remoteDirectoryPath: selectedSFTP?.currentPath,
            remoteFiles: selectedSFTP?.files ?? [],
            remoteEdits: remoteEdits.values
                .map(\.presentation)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
            tunnels: tunnels.values
                .sorted { $0.rule.name.localizedStandardCompare($1.rule.name) == .orderedAscending }
                .map(tunnelPresentation),
            snippets: workspaceDocument.snippets.map { snippet in
                SnippetPresentation(
                    id: snippet.id,
                    title: snippet.title,
                    summary: snippet.commands.first ?? "",
                    commandsText: snippet.commands.joined(separator: "\n"),
                    variables: snippet.variables.map {
                        SnippetVariablePresentation(
                            id: $0.id,
                            name: $0.name,
                            prompt: $0.prompt,
                            isSecret: $0.isSecret
                        )
                    }
                )
            },
            broadcastTargetSessionIDs: broadcastTargetSessionIDs,
            settings: settingsPresentation(from: workspaceDocument.settings),
            authenticationChallenge: authenticationChallenge
        )
    }

    private func presentation(for session: ManagedTerminalSession) -> TerminalSessionPresentation {
        TerminalSessionPresentation(
            id: session.id,
            title: session.descriptor.title,
            profileID: session.profileID,
            isLocal: session.isLocal,
            state: session.state,
            launch: session.launch,
            currentDirectory: session.currentDirectory,
            activeProcessDescription: session.isLocal
                ? localShellPath()
                : session.profileID.flatMap { id in profileDocument.profiles.first(where: { $0.id == id }) }
                    .map { "\($0.username)@\($0.host):\($0.port)" },
            supportsFileTransfer: !session.isLocal && session.state.isInputReady,
            isReadOnly: false,
            isSessionLoggingEnabled: session.descriptor.shouldLog,
            hasSessionLog: session.logFile != nil || FileManager.default.fileExists(atPath: sessionLogURL(for: session.id).path),
            pendingInput: session.pendingInput
        )
    }

    private func transferPresentation(_ managed: ManagedTransfer) -> TransferPresentation {
        let task = managed.task
        return TransferPresentation(
            id: task.id,
            displayName: task.localURL.lastPathComponent,
            sourceDescription: task.direction == .upload || task.direction == .scpUpload ? task.localURL.path : task.remotePath,
            destinationDescription: task.direction == .upload || task.direction == .scpUpload ? task.remotePath : task.localURL.path,
            bytesTransferred: task.bytesTransferred,
            totalBytes: task.totalBytes,
            phase: task.state == .completed && managed.skippedItemCount > 0
                ? .completedWithSkipped(managed.skippedItemCount)
                : transferPhase(task.state, message: task.errorMessage),
            sessionID: managed.sessionID
        )
    }

    private func tunnelPresentation(_ tunnel: ManagedTunnel) -> TunnelPresentation {
        TunnelPresentation(
            id: tunnel.id,
            name: tunnel.rule.name,
            direction: tunnelDirection(tunnel.rule.kind),
            bindAddress: tunnel.rule.bindAddress,
            listeningEndpoint: tunnelEndpoint(tunnel),
            destination: tunnelDestination(tunnel.rule),
            destinationReachability: tunnel.destinationReachability,
            phase: tunnel.phase,
            sessionID: tunnel.sessionID,
            isIndependent: tunnel.isIndependent
        )
    }

    private func emitSnapshot() {
        guard didLoad else { return }
        snapshotHandler?(makeSnapshot())
    }

    private func persistWorkspace() async throws {
        let descriptors = sessionOrder.compactMap { sessions[$0]?.descriptor }
        let snapshot = WorkspaceSnapshot(
            id: workspaceDocument.workspace.id,
            name: workspaceDocument.workspace.name,
            sessions: descriptors,
            layout: persistentLayout(),
            selectedSessionID: selectedSessionID
        )
        workspaceDocument.workspace = snapshot
        try await workspaceRepository.updateWorkspace(snapshot)
    }

    private func setPaneSelectionAfterAdding(_ sessionID: UUID) {
        switch workspaceLayout {
        case .single:
            paneSessionIDs = [sessionID]
        case .horizontalSplit, .verticalSplit:
            if paneSessionIDs.count < 2 {
                paneSessionIDs.append(sessionID)
            } else {
                paneSessionIDs[1] = sessionID
            }
        }
    }

    private func presentationLayout(from layout: TerminalLayoutNode?) -> WorkspaceLayoutPresentation {
        guard case let .split(axis, _, _, _)? = layout else { return .single }
        return axis == .horizontal ? .horizontalSplit : .verticalSplit
    }

    private func persistentLayout() -> TerminalLayoutNode? {
        switch workspaceLayout {
        case .single:
            return paneSessionIDs.first.map(TerminalLayoutNode.session)
        case .horizontalSplit:
            guard paneSessionIDs.count >= 2 else { return paneSessionIDs.first.map(TerminalLayoutNode.session) }
            return .split(axis: .horizontal, ratio: 0.5, leading: .session(paneSessionIDs[0]), trailing: .session(paneSessionIDs[1]))
        case .verticalSplit:
            guard paneSessionIDs.count >= 2 else { return paneSessionIDs.first.map(TerminalLayoutNode.session) }
            return .split(axis: .vertical, ratio: 0.5, leading: .session(paneSessionIDs[0]), trailing: .session(paneSessionIDs[1]))
        }
    }

    private func layoutSessionIDs(in layout: TerminalLayoutNode?) -> [UUID] {
        guard let layout else { return [] }
        switch layout {
        case let .session(id): return [id]
        case let .split(_, _, leading, trailing): return layoutSessionIDs(in: leading) + layoutSessionIDs(in: trailing)
        }
    }

    // MARK: Profile conversion and secret storage

    private func profileDraft(from profile: ConnectionProfile) -> ProfileDraftPresentation {
        let authenticationMethod: AuthenticationMethodPresentation
        let identityFilePath: String
        let agentSocketPath: String
        switch profile.authentication {
        case let .agent(socket):
            authenticationMethod = .sshAgent
            identityFilePath = ""
            agentSocketPath = socket ?? ""
        case let .privateKey(path, _):
            authenticationMethod = profile.certificatePath == nil ? .privateKey : .certificate
            identityFilePath = path
            agentSocketPath = ""
        case .password:
            authenticationMethod = .password
            identityFilePath = ""
            agentSocketPath = ""
        case .keyboardInteractive:
            authenticationMethod = .keyboardInteractive
            identityFilePath = ""
            agentSocketPath = ""
        }
        return ProfileDraftPresentation(
            id: profile.id,
            name: profile.name,
            host: profile.host,
            port: String(profile.port),
            username: profile.username,
            authenticationMethod: authenticationMethod,
            identityFilePath: identityFilePath,
            certificateFilePath: profile.certificatePath ?? "",
            agentSocketPath: agentSocketPath,
            jumpProfileIDs: profile.jumpProfileIDs,
            proxyKind: proxyPresentation(profile.proxy?.kind),
            proxyHost: profile.proxy?.host ?? "",
            proxyPort: profile.proxy.map { String($0.port) } ?? "",
            proxyUsername: profile.proxy?.username ?? "",
            agentForwardingEnabled: profile.options.forwardAgent,
            connectTimeoutSeconds: String(Int(profile.options.connectTimeout)),
            keepaliveSeconds: String(Int(profile.options.serverAliveInterval)),
            autoReconnectEnabled: profile.options.autoReconnect,
            forwardingRules: profile.forwardingRules.map(forwardingDraft),
            tags: profile.tags,
            folderID: profile.folderID,
            isFavorite: profile.isFavorite
        )
    }

    private func makeProfile(
        from submission: ProfileEditorSubmission,
        prior: ConnectionProfile?
    ) throws -> ConnectionProfile {
        let draft = submission.draft
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty,
              let port = Int(draft.port), (1 ... 65_535).contains(port) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string("Enter a name, host, user name and valid port.", korean: "이름, 호스트, 사용자 이름과 올바른 포트를 입력하세요."))
        }
        guard !draft.jumpProfileIDs.contains(draft.id) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string("A connection cannot jump through itself.", korean: "연결은 자기 자신을 Jump host로 참조할 수 없습니다."))
        }
        let existingAuthentication = prior?.authentication
        let authentication: AuthenticationMethod
        switch draft.authenticationMethod {
        case .sshAgent:
            let socket = draft.agentSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
            authentication = .agent(socketPath: socket.isEmpty ? nil : socket)
        case .privateKey, .certificate:
            let path = draft.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { throw CoreWorkspaceServiceError.invalidProfile(AppText.string("Choose a private key file.", korean: "개인 키 파일을 선택하세요.")) }
            var reference: SecretReference?
            if !submission.secrets.privateKeyPassphrase.isEmpty {
                reference = existingPassphraseReference(existingAuthentication) ?? SecretReference()
                try keychain.save(submission.secrets.privateKeyPassphrase, for: reference!)
            } else {
                reference = existingPassphraseReference(existingAuthentication)
            }
            authentication = .privateKey(path: path, passphrase: reference)
        case .password:
            let reference = existingPasswordReference(existingAuthentication) ?? SecretReference()
            if !submission.secrets.password.isEmpty {
                try keychain.save(submission.secrets.password, for: reference)
            }
            authentication = .password(secret: reference)
        case .keyboardInteractive:
            authentication = .keyboardInteractive(secret: existingKeyboardInteractiveReference(existingAuthentication))
        }

        let proxy = try makeProxy(from: submission, prior: prior?.proxy)
        let forwardings = try draft.forwardingRules.map(forwardingRule)
        let timeout = try positiveInterval(draft.connectTimeoutSeconds, field: AppText.string("Connect timeout", korean: "연결 제한 시간"))
        let keepalive = try nonnegativeInterval(draft.keepaliveSeconds, field: AppText.string("Keepalive", korean: "Keepalive"))
        let certificate = draft.authenticationMethod == .certificate
            ? optionalPath(draft.certificateFilePath)
            : nil
        if draft.authenticationMethod == .certificate, certificate == nil {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string("Choose an SSH certificate file.", korean: "SSH 인증서 파일을 선택하세요."))
        }
        return ConnectionProfile(
            id: draft.id,
            name: name,
            folderID: draft.folderID,
            tags: draft.tags,
            isFavorite: draft.isFavorite,
            host: host,
            port: port,
            username: username,
            authentication: authentication,
            certificatePath: certificate,
            jumpProfileIDs: draft.jumpProfileIDs,
            proxy: proxy,
            options: SSHOptions(
                connectTimeout: timeout,
                serverAliveInterval: keepalive,
                serverAliveCountMax: prior?.options.serverAliveCountMax ?? SSHOptions.default.serverAliveCountMax,
                autoReconnect: draft.autoReconnectEnabled,
                maximumReconnectAttempts: prior?.options.maximumReconnectAttempts ?? SSHOptions.default.maximumReconnectAttempts,
                forwardAgent: draft.agentForwardingEnabled,
                requestTTY: prior?.options.requestTTY ?? true
            ),
            forwardingRules: forwardings,
            createdAt: prior?.createdAt ?? .now
        )
    }

    private func makeProxy(from submission: ProfileEditorSubmission, prior: ProxyConfiguration?) throws -> ProxyConfiguration? {
        let draft = submission.draft
        guard draft.proxyKind != .none else { return nil }
        let host = draft.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(draft.proxyPort), (1 ... 65_535).contains(port) else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string("Enter a valid proxy host and port.", korean: "올바른 프록시 호스트와 포트를 입력하세요."))
        }
        let username = optionalText(draft.proxyUsername)
        var reference = prior?.password
        if !submission.secrets.proxyPassword.isEmpty {
            reference = reference ?? SecretReference()
            try keychain.save(submission.secrets.proxyPassword, for: reference!)
        }
        return ProxyConfiguration(
            kind: draft.proxyKind == .httpConnect ? .httpConnect : .socks5,
            host: host,
            port: port,
            username: username,
            password: username == nil ? nil : reference
        )
    }

    private func duplicateAuthenticationReference(_ authentication: AuthenticationMethod) -> AuthenticationMethod {
        switch authentication {
        case let .agent(path): .agent(socketPath: path)
        case let .privateKey(path, _): .privateKey(path: path, passphrase: nil)
        case .password: .password(secret: SecretReference())
        case .keyboardInteractive: .keyboardInteractive(secret: nil)
        }
    }

    private func deleteSecrets(referencedBy profile: ConnectionProfile) {
        switch profile.authentication {
        case let .privateKey(_, passphrase): if let passphrase { try? keychain.delete(passphrase) }
        case let .password(secret): try? keychain.delete(secret)
        case let .keyboardInteractive(secret): if let secret { try? keychain.delete(secret) }
        case .agent: break
        }
        if let secret = profile.proxy?.password { try? keychain.delete(secret) }
    }

    // MARK: OpenSSH process preparation

    private func launchSSH(
        session: ManagedTerminalSession,
        profile: ConnectionProfile,
        hostKeyPolicy: OpenSSHHostKeyPolicy
    ) async throws {
        let route = try SSHRouteResolver.resolve(target: profile, profiles: profileDocument.profiles)
        let capabilities = try OpenSSHCapabilities.current()
        try capabilities.validate(route: route, forwardingRules: [])

        session.credentialBroker?.stop()
        session.preparedCommand?.configuration.cleanup()
        session.challengeGate?.cancelAll()

        let sessionID = session.id
        let gate = CredentialChallengeGate(sessionID: sessionID)
        gate.presenter = { [weak self, weak gate] challenge in
            Task { @MainActor [weak self, weak gate] in
                guard let self, let gate else { return }
                self.challengeGates[challenge.id] = gate
                self.authenticationChallenge = challenge
                if let managed = self.sessions[sessionID], !managed.isLocal {
                    managed.state = .authenticating(AppText.string("Waiting for authentication", korean: "인증 응답 대기 중"))
                }
                self.emitSnapshot()
            }
        }

        let broker = try makeCredentialBroker(route: route, gate: gate)
        let proxyHelper = try makeProxyHelperConfiguration(route: route, broker: broker, sessionID: sessionID)
        do {
            let prepared = try OpenSSHCommandCompiler().prepare(
                route: route,
                knownHostsURL: knownHostsURL,
                proxyHelper: proxyHelper,
                hostKeyPolicy: hostKeyPolicy,
                purpose: .interactive,
                baseDirectory: FileManager.default.temporaryDirectory
            )
            session.route = route
            session.preparedCommand = prepared
            session.credentialBroker = broker
            session.challengeGate = gate
            session.userRequestedStop = false
            session.state = .connecting
            session.launch = TerminalProcessLaunchPresentation(
                launchID: UUID(),
                executable: prepared.invocation.executableURL.path,
                arguments: prepared.invocation.arguments,
                environment: terminalEnvironment(overrides: try askPassEnvironment(broker: broker)),
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        } catch {
            broker.stop()
            throw error
        }
    }

    private func makeCredentialBroker(
        route: ResolvedSSHRoute,
        gate: CredentialChallengeGate
    ) throws -> SessionCredentialBroker {
        let responses = try storedCredentialResponses(for: route)
        return try SessionCredentialBroker(
            responses: responses,
            requestHandler: { request in
                gate.requestResponse(for: request)
            },
            baseDirectory: FileManager.default.temporaryDirectory
        )
    }

    private func storedCredentialResponses(for route: ResolvedSSHRoute) throws -> [String: String] {
        var responses: [String: String] = [:]
        for profile in route.profiles {
            let reference: SecretReference?
            let markers: [String]
            switch profile.authentication {
            case let .privateKey(path, passphrase):
                reference = passphrase
                markers = [
                    "passphrase for key '\(path.lowercased())'",
                    "passphrase"
                ]
            case let .password(secret):
                reference = secret
                markers = [
                    "\(profile.username.lowercased())@\(profile.host.lowercased())'s password",
                    "\(profile.host.lowercased())'s password"
                ]
            case let .keyboardInteractive(secret):
                reference = secret
                markers = [
                    "\(profile.username.lowercased())@\(profile.host.lowercased())",
                    "keyboard-interactive"
                ]
            case .agent:
                reference = nil
                markers = []
            }
            guard let reference, let value = try keychain.read(reference), !value.isEmpty else { continue }
            for marker in markers where responses[marker] == nil {
                responses[marker] = value
            }
        }

        if let proxy = try route.localTransportProxy(),
           let username = proxy.username,
           let reference = proxy.password,
           let value = try keychain.read(reference), !value.isEmpty {
            responses[ProxyCredentialPrompt.make(username: username, host: proxy.host, port: proxy.port).lowercased()] = value
        }
        return responses
    }

    private func makeProxyHelperConfiguration(
        route: ResolvedSSHRoute,
        broker: SessionCredentialBroker,
        sessionID: UUID
    ) throws -> ProxyHelperLaunchConfiguration? {
        guard try route.localTransportProxy() != nil else { return nil }
        return ProxyHelperLaunchConfiguration(
            executableURL: try helperExecutableURL(named: "osXtermProxy"),
            socketPath: broker.socketPath,
            token: broker.token,
            sessionID: sessionID
        )
    }

    private func askPassEnvironment(broker: SessionCredentialBroker) throws -> [String: String] {
        [
            "SSH_ASKPASS": try helperExecutableURL(named: "osXtermAskPass").path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "osxterm:0",
            "OSXTERM_ASKPASS_SOCKET": broker.socketPath,
            "OSXTERM_ASKPASS_TOKEN": broker.token
        ]
    }

    private func helperExecutableURL(named name: String) throws -> URL {
        let executablePath = CommandLine.arguments.first ?? ""
        guard !executablePath.isEmpty else {
            throw CoreWorkspaceServiceError.helperUnavailable(name)
        }
        do {
            return try PackagedHelperLocator.locate(
                named: name,
                bundleURL: Bundle.main.bundleURL,
                executableURL: URL(fileURLWithPath: executablePath)
            )
        } catch {
            throw CoreWorkspaceServiceError.helperUnavailable(name)
        }
    }

    private func terminalEnvironment(overrides: [String: String]) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    private func processEnvironment(overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private func localShellPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    // MARK: SFTP v3

    private func sftpConnection(for session: ManagedTerminalSession) async throws -> ManagedSFTPConnection {
        if let existing = sftpConnections[session.id] { return existing }
        guard let profileID = session.profileID,
              let profile = profileDocument.profiles.first(where: { $0.id == profileID }),
              session.state.isInputReady
        else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }

        let route = try SSHRouteResolver.resolve(target: profile, profiles: profileDocument.profiles)
        let capabilities = try OpenSSHCapabilities.current()
        try capabilities.validate(route: route, forwardingRules: [])
        let sessionID = session.id
        let gate = CredentialChallengeGate(sessionID: sessionID)
        gate.presenter = { [weak self, weak gate] challenge in
            Task { @MainActor [weak self, weak gate] in
                guard let self, let gate else { return }
                self.challengeGates[challenge.id] = gate
                self.authenticationChallenge = challenge
                self.emitSnapshot()
            }
        }
        let broker = try makeCredentialBroker(route: route, gate: gate)
        do {
            let proxyHelper = try makeProxyHelperConfiguration(route: route, broker: broker, sessionID: sessionID)
            let prepared = try OpenSSHCommandCompiler().prepare(
                route: route,
                knownHostsURL: knownHostsURL,
                proxyHelper: proxyHelper,
                hostKeyPolicy: .requireKnown,
                purpose: .subsystem("sftp"),
                baseDirectory: FileManager.default.temporaryDirectory
            )
            let transport = try SFTPProcessTransport(
                preparedCommand: prepared,
                environment: processEnvironment(overrides: try askPassEnvironment(broker: broker)),
                diagnosticsHandler: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, let managed = self.sessions[sessionID] else { return }
                        self.appendOutput(Data(text.utf8), to: managed)
                    }
                }
            )
            let client = SFTPClient(transport: transport)
            _ = try await client.initialize()
            let connection = ManagedSFTPConnection(
                client: client,
                transport: transport,
                credentialBroker: broker,
                challengeGate: gate
            )
            sftpConnections[sessionID] = connection
            try await refreshRemoteFiles(connection)
            return connection
        } catch {
            broker.stop()
            throw error
        }
    }

    private func requireReadySFTP(sessionID: UUID) async throws -> ManagedSFTPConnection {
        guard let session = sessions[sessionID], session.state.isInputReady else {
            throw CoreWorkspaceServiceError.sessionNotReady
        }
        return try await sftpConnection(for: session)
    }

    private func refreshRemoteFiles(_ connection: ManagedSFTPConnection) async throws {
        let directory = try SFTPRemotePath(rawValue: connection.currentPath)
        let entries = try await connection.client.listDirectory(directory)
        var files: [RemoteFilePresentation] = []
        for entry in entries where entry.filename != "." && entry.filename != ".." {
            let absolutePath = joinRemotePath(connection.currentPath, entry.filename)
            let kind: RemoteFileKindPresentation
            if isRemoteDirectory(entry.attributes) {
                kind = .directory
            } else if isRemoteSymbolicLink(entry.attributes) {
                let target = try? await connection.client.symbolicLinkTarget(at: SFTPRemotePath(rawValue: absolutePath))
                kind = .symbolicLink(target: target)
            } else {
                kind = .file
            }
            files.append(
                RemoteFilePresentation(
                    id: absolutePath,
                    name: entry.filename,
                    absolutePath: absolutePath,
                    kind: kind,
                    size: entry.attributes.size.flatMap(Int64.init),
                    modifiedAt: entry.attributes.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    permissions: permissionString(entry.attributes.permissions)
                )
            )
        }
        connection.files = files.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func removeRemoteDirectoryRecursively(
        _ path: SFTPRemotePath,
        client: SFTPClient
    ) async throws {
        let entries = try await client.listDirectory(path)
        for entry in entries where entry.filename != "." && entry.filename != ".." {
            let child = try SFTPRemotePath(rawValue: joinRemotePath(path.rawValue, entry.filename))
            if isRemoteDirectory(entry.attributes) {
                try await removeRemoteDirectoryRecursively(child, client: client)
            } else {
                try await client.remove(child)
            }
        }
        try await client.removeDirectory(path)
    }

    private func isRemoteDirectory(_ attributes: SFTPFileAttributes) -> Bool {
        (attributes.permissions ?? 0) & 0o170000 == 0o040000
    }

    private func isRemoteSymbolicLink(_ attributes: SFTPFileAttributes) -> Bool {
        (attributes.permissions ?? 0) & 0o170000 == 0o120000
    }

    private func permissionString(_ permissions: UInt32?) -> String? {
        guard let permissions else { return nil }
        return String(format: "%04o", permissions & 0o7777)
    }

    private func safeRemoteName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\0")
        else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string("Enter a valid remote name.", korean: "올바른 원격 이름을 입력하세요."))
        }
        return trimmed
    }

    private func isSafeSnippetVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
        else {
            return false
        }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }

    private func snippetComponents(
        title: String,
        commandsText: String
    ) throws -> (title: String, commands: [String], variables: [CommandSnippetVariable]) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = commandsText
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !trimmedTitle.isEmpty, trimmedTitle.count <= 120, !commands.isEmpty else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Enter a title and at least one command line.",
                korean: "제목과 하나 이상의 명령 줄을 입력하세요."
            ))
        }
        return (trimmedTitle, commands, try snippetVariables(in: commands))
    }

    private func snippetVariables(in commands: [String]) throws -> [CommandSnippetVariable] {
        let text = commands.joined(separator: "\n")
        let expression = try NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        var names: [String] = []
        for match in matches {
            guard let capture = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeSnippetVariableName(name) else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "Snippet variables use {{name}} with letters, numbers, and underscores.",
                    korean: "스니펫 변수는 문자, 숫자, 밑줄을 사용한 {{name}} 형식이어야 합니다."
                ))
            }
            if !names.contains(name) { names.append(name) }
        }
        let remaining = expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        guard !remaining.contains("{{"), !remaining.contains("}}") else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Every snippet variable must use a complete {{name}} placeholder.",
                korean: "모든 스니펫 변수는 완전한 {{name}} 자리표시자여야 합니다."
            ))
        }
        return names.map { CommandSnippetVariable(name: $0, prompt: $0) }
    }

    private func joinRemotePath(_ base: String, _ component: String) -> String {
        if base == "/" { return "/\(component)" }
        if base == "." { return "./\(component)" }
        return base.hasSuffix("/") ? base + component : base + "/" + component
    }

    private func remoteParent(_ path: String) -> String {
        if path == "/" || path == "." { return path }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = normalized.lastIndex(of: "/") else { return "." }
        if slash == normalized.startIndex { return "/" }
        return String(normalized[..<slash])
    }

    // MARK: Transfer queue

    private func beginTransfer(_ transfer: ManagedTransfer) {
        transfer.work?.cancel()
        transfer.process?.terminate()
        transfer.diagnostics.removeAll(keepingCapacity: true)
        transfer.skippedItemCount = 0
        let transferID = transfer.id
        transfer.work = Task { [weak self] in
            guard let self else { return }
            await self.executeTransfer(id: transferID)
        }
    }

    private func executeTransfer(id: UUID) async {
        guard let transfer = transfers[id] else { return }
        do {
            transfer.task = try TransferTaskStateMachine.apply(.beginPreparation, to: transfer.task)
            emitSnapshot()
            switch transfer.task.direction {
            case .upload:
                let connection = try await requireReadySFTP(sessionID: transfer.sessionID)
                let totalBytes = try await transferTotalBytes(for: transfer.task, client: connection.client)
                transfer.task = try TransferTaskStateMachine.apply(.begin(totalBytes: totalBytes), to: transfer.task)
                emitSnapshot()
                try await upload(localURL: transfer.task.localURL, to: transfer.task.remotePath, transferID: id, client: connection.client)
            case .download:
                let connection = try await requireReadySFTP(sessionID: transfer.sessionID)
                let totalBytes = try await transferTotalBytes(for: transfer.task, client: connection.client)
                transfer.task = try TransferTaskStateMachine.apply(.begin(totalBytes: totalBytes), to: transfer.task)
                emitSnapshot()
                try await download(remotePath: transfer.task.remotePath, to: transfer.task.localURL, transferID: id, client: connection.client)
            case .scpUpload, .scpDownload:
                _ = try TransferPlanner.plan(transfer.task)
                let totalBytes = try await scpTransferTotalBytes(for: transfer.task)
                transfer.task = try TransferTaskStateMachine.apply(.begin(totalBytes: totalBytes), to: transfer.task)
                emitSnapshot()
                if try await resumeSCPTransferViaSFTPIfSafe(transfer) == false {
                    try await runSCPTransfer(transfer)
                }
            }

            guard let current = transfers[id] else { return }
            if current.task.state == .cancelling {
                current.task = try TransferTaskStateMachine.apply(.cancel, to: current.task)
            } else {
                if current.skippedItemCount > 0 {
                    current.task.totalBytes = current.task.bytesTransferred
                }
                current.task = try TransferTaskStateMachine.apply(.complete, to: current.task)
            }
            emitSnapshot()
        } catch TransferConflictOutcome.skipItem {
            transfer.skippedItemCount += 1
            transfer.task.totalBytes = transfer.task.bytesTransferred
            transfer.task = (try? TransferTaskStateMachine.apply(.complete, to: transfer.task)) ?? transfer.task
            emitSnapshot()
        } catch is CancellationError {
            finishCancelledTransfer(id: id)
        } catch {
            if transfers[id]?.task.state == .cancelling {
                finishCancelledTransfer(id: id)
            } else if let current = transfers[id] {
                current.task = (try? TransferTaskStateMachine.apply(
                    .fail(message: OpenSSHOutputSanitizer.displayMessage(error.localizedDescription)),
                    to: current.task
                )) ?? current.task
                emitSnapshot()
            }
        }
    }

    private func scpTransferTotalBytes(for task: TransferTask) async throws -> Int64? {
        switch task.direction {
        case .scpUpload:
            let values = try task.localURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true { return try recursiveLocalSize(at: task.localURL) }
            return values.fileSize.map(Int64.init)
        case .scpDownload:
            return task.totalBytes
        case .upload, .download:
            return task.totalBytes
        }
    }

    /// OpenSSH's `scp` process has no append mode. When a single-file SCP task
    /// has an unchanged recorded source and a digest-verified partial prefix,
    /// continue it through the already-established SFTP subsystem instead.
    /// SCP is invoked with `-s`, so this uses the same SSH route and structured
    /// file protocol without asking a legacy remote shell to interpret a path.
    /// Recursive SCP tasks intentionally restart: their initial subprocess has
    /// no trusted per-leaf conflict manifest to prove which renamed child can
    /// be safely continued.
    private func resumeSCPTransferViaSFTPIfSafe(_ transfer: ManagedTransfer) async throws -> Bool {
        guard transfer.task.retryCount > 0,
              !transfer.task.isRecursive,
              let previousSource = transfer.task.sourceFingerprint
        else {
            return false
        }

        let connection = try await requireReadySFTP(sessionID: transfer.sessionID)
        switch transfer.task.direction {
        case .scpUpload:
            let localURL = transfer.task.localURL
            let remotePath = try SFTPRemotePath(rawValue: transfer.task.remotePath)
            let currentSource = try localTransferFingerprint(at: localURL)
            guard currentSource == previousSource else { return false }
            let existingBytes = try await existingRemoteFileSize(at: remotePath, client: connection.client)
            let decision = try await verifiedResumeDecision(
                localURL: localURL,
                remotePath: remotePath,
                existingDestinationBytes: existingBytes,
                previousSource: previousSource,
                currentSource: currentSource,
                client: connection.client
            )
            guard decision != .restart else { return false }
            try await upload(
                localURL: localURL,
                to: remotePath.rawValue,
                transferID: transfer.id,
                client: connection.client
            )
            return true
        case .scpDownload:
            let localURL = transfer.task.localURL
            let remotePath = try SFTPRemotePath(rawValue: transfer.task.remotePath)
            let currentSource = try await remoteTransferFingerprint(at: remotePath, client: connection.client)
            guard currentSource == previousSource else { return false }
            let existingBytes = try existingLocalFileSize(at: localURL)
            let decision = try await verifiedResumeDecision(
                localURL: localURL,
                remotePath: remotePath,
                existingDestinationBytes: existingBytes,
                previousSource: previousSource,
                currentSource: currentSource,
                client: connection.client
            )
            guard decision != .restart else { return false }
            try await download(
                remotePath: remotePath.rawValue,
                to: localURL,
                transferID: transfer.id,
                client: connection.client
            )
            return true
        case .upload, .download:
            return false
        }
    }

    /// Runs `scp` with the same generated OpenSSH route as interactive SSH,
    /// SFTP and tunnels. Operands are never interpolated into a shell command.
    /// `-s` forces the SFTP transport for SCP so a legacy remote shell is not
    /// used to interpret a remote pathname.
    private func runSCPTransfer(_ transfer: ManagedTransfer) async throws {
        try Task.checkCancellation()
        guard let profile = profileDocument.profiles.first(where: { $0.id == transfer.task.profileID }) else {
            throw CoreWorkspaceServiceError.profileNotFound
        }

        let route = try SSHRouteResolver.resolve(target: profile, profiles: profileDocument.profiles)
        let capabilities = try OpenSSHCapabilities.current()
        try capabilities.validate(route: route, forwardingRules: [])
        try capabilities.validateSFTPBackedSCP()

        let transferID = transfer.id
        let gate = CredentialChallengeGate(sessionID: transfer.sessionID)
        gate.presenter = { [weak self, weak gate] challenge in
            Task { @MainActor [weak self, weak gate] in
                guard let self, let gate else { return }
                self.challengeGates[challenge.id] = gate
                self.authenticationChallenge = challenge
                self.emitSnapshot()
            }
        }

        let broker = try makeCredentialBroker(route: route, gate: gate)
        do {
            let proxyHelper = try makeProxyHelperConfiguration(route: route, broker: broker, sessionID: transferID)
            let prepared = try OpenSSHCommandCompiler().prepareSCP(
                route: route,
                knownHostsURL: knownHostsURL,
                proxyHelper: proxyHelper,
                hostKeyPolicy: .promptUser,
                baseDirectory: FileManager.default.temporaryDirectory
            )
            var planned = try TransferPlanner.plan(transfer.task)

            switch planned.operation {
            case .upload:
                let connection = try await requireReadySFTP(sessionID: transfer.sessionID)
                let resolvedRemote = try await resolvedRemoteDestination(
                    planned.remotePath,
                    transferID: transferID,
                    client: connection.client
                )
                transfer.task.remotePath = resolvedRemote.rawValue
                planned = try TransferPlanner.plan(transfer.task)
            case .download:
                let resolvedLocal = try resolvedLocalDestination(
                    planned.localURL,
                    isDirectory: planned.isRecursive,
                    transferID: transferID
                )
                transfer.task.localURL = resolvedLocal
                planned = try TransferPlanner.plan(transfer.task)
            }
            let sourceBeforeTransfer: TransferSourceFingerprint?
            if planned.isRecursive {
                sourceBeforeTransfer = nil
            } else {
                switch planned.operation {
                case .upload:
                    sourceBeforeTransfer = try localTransferFingerprint(at: planned.localURL)
                case .download:
                    let connection = try await requireReadySFTP(sessionID: transfer.sessionID)
                    sourceBeforeTransfer = try await remoteTransferFingerprint(
                        at: planned.remotePath,
                        client: connection.client
                    )
                }
            }
            transfer.task.sourceFingerprint = sourceBeforeTransfer
            emitSnapshot()

            let remoteOperand = "\(prepared.configuration.targetAlias):\(planned.remotePath.rawValue)"
            var arguments = prepared.invocation.arguments
            arguments.append("-s")
            if planned.isRecursive { arguments.append("-r") }
            switch planned.operation {
            case .upload:
                arguments.append(planned.localURL.path)
                arguments.append(remoteOperand)
            case .download:
                arguments.append(remoteOperand)
                arguments.append(planned.localURL.path)
            }

            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = prepared.invocation.executableURL
            process.arguments = arguments
            process.environment = processEnvironment(overrides: try askPassEnvironment(broker: broker))
            process.standardOutput = output
            process.standardError = error
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
            }
            error.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                Task { @MainActor [weak self] in
                    self?.appendSCPDiagnostics(data, transferID: transferID)
                }
            }

            transfer.process = process
            transfer.preparedCommand = prepared
            transfer.credentialBroker = broker
            transfer.challengeGate = gate
            defer { cleanSCPResources(transfer) }

            let status = try await runProcessAndWait(process)
            try Task.checkCancellation()
            guard status == 0 else {
                let diagnostics = OpenSSHOutputSanitizer.displayMessage(
                    String(decoding: transfer.diagnostics, as: UTF8.self),
                    limit: 1_024
                )
                throw CoreWorkspaceServiceError.invalidProfile(
                    diagnostics.isEmpty
                        ? AppText.string(
                            "SCP exited with status \(status).",
                            korean: "SCP가 상태 \(status)로 종료되었습니다."
                        )
                        : AppText.string(
                            "SCP failed: \(diagnostics)",
                            korean: "SCP 전송에 실패했습니다: \(diagnostics)"
                        )
                )
            }
            if let sourceBeforeTransfer {
                let sourceAfterTransfer: TransferSourceFingerprint
                switch planned.operation {
                case .upload:
                    sourceAfterTransfer = try localTransferFingerprint(at: planned.localURL)
                case .download:
                    let connection = try await requireReadySFTP(sessionID: transfer.sessionID)
                    sourceAfterTransfer = try await remoteTransferFingerprint(
                        at: planned.remotePath,
                        client: connection.client
                    )
                }
                guard sourceAfterTransfer == sourceBeforeTransfer else {
                    throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                        "The source changed while SCP was transferring it. The retry will restart safely.",
                        korean: "SCP 전송 중 원본이 변경되었습니다. 다시 시도하면 안전하게 처음부터 전송합니다."
                    ))
                }
            }
            if let total = transfer.task.totalBytes {
                transfer.task = try TransferTaskStateMachine.apply(
                    .updateProgress(bytesTransferred: total, totalBytes: total),
                    to: transfer.task
                )
                emitSnapshot()
            }
        } catch {
            broker.stop()
            throw error
        }
    }

    private func runProcessAndWait(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completed in
                continuation.resume(returning: completed.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func appendSCPDiagnostics(_ data: Data, transferID: UUID) {
        guard let transfer = transfers[transferID] else { return }
        let maximum = 64 * 1024
        if transfer.diagnostics.count + data.count > maximum {
            transfer.diagnostics = Data(transfer.diagnostics.suffix(max(0, maximum - data.count)))
        }
        transfer.diagnostics.append(data)
    }

    private func cleanSCPResources(_ transfer: ManagedTransfer) {
        if let output = transfer.process?.standardOutput as? Pipe {
            output.fileHandleForReading.readabilityHandler = nil
        }
        if let error = transfer.process?.standardError as? Pipe {
            error.fileHandleForReading.readabilityHandler = nil
        }
        transfer.process?.terminationHandler = nil
        transfer.credentialBroker?.stop()
        transfer.credentialBroker = nil
        transfer.challengeGate?.cancelAll()
        transfer.challengeGate = nil
        transfer.preparedCommand?.configuration.cleanup()
        transfer.preparedCommand = nil
        transfer.process = nil
    }

    private func finishCancelledTransfer(id: UUID) {
        guard let transfer = transfers[id] else { return }
        if transfer.task.state == .queued || transfer.task.state == .preparing || transfer.task.state == .running || transfer.task.state == .paused {
            transfer.task = (try? TransferTaskStateMachine.apply(.requestCancellation, to: transfer.task)) ?? transfer.task
        }
        if transfer.task.state == .cancelling {
            transfer.task = (try? TransferTaskStateMachine.apply(.cancel, to: transfer.task)) ?? transfer.task
        }
        emitSnapshot()
    }

    private func transferTotalBytes(for task: TransferTask, client: SFTPClient) async throws -> Int64? {
        switch task.direction {
        case .upload:
            let values = try task.localURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true { return try recursiveLocalSize(at: task.localURL) }
            return values.fileSize.map(Int64.init)
        case .download:
            let attributes = try await client.attributes(of: SFTPRemotePath(rawValue: task.remotePath), followSymlink: false)
            if isRemoteDirectory(attributes) { return nil }
            return attributes.size.flatMap(Int64.init)
        case .scpUpload, .scpDownload:
            return task.totalBytes
        }
    }

    private func upload(
        localURL: URL,
        to remotePath: String,
        transferID: UUID,
        client: SFTPClient
    ) async throws {
        do {
            try await uploadItem(localURL: localURL, to: remotePath, transferID: transferID, client: client)
        } catch TransferConflictOutcome.skipItem {
            transfers[transferID]?.skippedItemCount += 1
        }
    }

    private func uploadItem(
        localURL: URL,
        to remotePath: String,
        transferID: UUID,
        client: SFTPClient
    ) async throws {
        try Task.checkCancellation()
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let destination = try SFTPRemotePath(rawValue: remotePath)
        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: localURL.path)
            let resolved = try await resolvedRemoteDestination(destination, transferID: transferID, client: client)
            do {
                let existing = try await client.attributes(of: resolved, followSymlink: false)
                guard !isRemoteDirectory(existing) else {
                    throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                        "A folder cannot be overwritten by a symbolic link.",
                        korean: "폴더를 심볼릭 링크로 덮어쓸 수 없습니다."
                    ))
                }
                try await client.remove(resolved)
            } catch let error as SFTPClientError {
                guard case .remoteStatus(_, .noSuchFile, _) = error else { throw error }
            }
            try await client.createSymbolicLink(at: resolved, pointingTo: SFTPRemotePath(rawValue: target))
        } else if values.isDirectory == true {
            guard let transfer = transfers[transferID] else { throw CoreWorkspaceServiceError.transferNotFound }
            let key = try RecursiveTransferResumeKey.localFile(at: localURL)
            let resolved: SFTPRemotePath
            if transfer.task.retryCount > 0,
               case let .remoteFile(saved)? = transfer.recursiveResumeLedger.directoryDestination(for: key) {
                resolved = saved
            } else {
                resolved = try await resolvedRemoteDestination(destination, transferID: transferID, client: client)
            }
            try await ensureRemoteDirectory(resolved, client: client)
            transfer.recursiveResumeLedger.recordDirectory(.remoteFile(resolved), for: key)
            if localURL == transfer.task.localURL { transfer.task.remotePath = resolved.rawValue }
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                try await upload(
                    localURL: child,
                    to: joinRemotePath(resolved.rawValue, child.lastPathComponent),
                    transferID: transferID,
                    client: client
                )
            }
        } else {
            try await uploadFile(localURL: localURL, to: destination, transferID: transferID, client: client)
        }
    }

    private func uploadFile(
        localURL: URL,
        to destination: SFTPRemotePath,
        transferID: UUID,
        client: SFTPClient
    ) async throws {
        guard let transfer = transfers[transferID] else { throw CoreWorkspaceServiceError.transferNotFound }
        let currentSource = try localTransferFingerprint(at: localURL)
        let isRetryingSingleFile = !transfer.task.isRecursive
            && transfer.task.retryCount > 0
            && transfer.task.sourceFingerprint != nil
        let resolvedDestination: SFTPRemotePath
        let previousSource: TransferSourceFingerprint?
        let shouldAttemptResume: Bool
        if transfer.task.isRecursive {
            let resumeKey = try RecursiveTransferResumeKey.localFile(at: localURL)
            if transfer.task.retryCount > 0,
               let checkpoint = transfer.recursiveResumeLedger.checkpoint(for: resumeKey) {
                guard case let .remoteFile(savedDestination) = checkpoint.destination else {
                    throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                        "The recursive upload checkpoint has an invalid destination.",
                        korean: "재귀 업로드 재개 기록의 대상이 올바르지 않습니다."
                    ))
                }
                resolvedDestination = savedDestination
                previousSource = checkpoint.sourceFingerprint
                shouldAttemptResume = true
            } else {
                resolvedDestination = try await resolvedRemoteDestination(destination, transferID: transferID, client: client)
                previousSource = nil
                shouldAttemptResume = false
            }
            transfer.recursiveResumeLedger.record(
                RecursiveTransferResumeCheckpoint(
                    sourceFingerprint: currentSource,
                    destination: .remoteFile(resolvedDestination)
                ),
                for: resumeKey
            )
        } else if isRetryingSingleFile {
            resolvedDestination = destination
            previousSource = transfer.task.sourceFingerprint
            shouldAttemptResume = true
        } else {
            resolvedDestination = try await resolvedRemoteDestination(destination, transferID: transferID, client: client)
            transfer.task.remotePath = resolvedDestination.rawValue
            previousSource = nil
            shouldAttemptResume = false
        }

        let existingRemoteBytes = try await existingRemoteFileSize(
            at: resolvedDestination,
            client: client
        )
        let resumeDecision: TransferResumeDecision
        if shouldAttemptResume, let previousSource {
            resumeDecision = try await verifiedResumeDecision(
                localURL: localURL,
                remotePath: resolvedDestination,
                existingDestinationBytes: existingRemoteBytes,
                previousSource: previousSource,
                currentSource: currentSource,
                client: client
            )
        } else {
            resumeDecision = .restart
        }
        let resumeOffset: Int64
        switch resumeDecision {
        case let .resume(fromOffset):
            resumeOffset = fromOffset
        case .alreadyComplete:
            try ensureLocalSourceIsUnchanged(currentSource, at: localURL)
            reportRecoveredTransferProgress(transfer, transferID: transferID, bytes: currentSource.size)
            return
        case .restart:
            resumeOffset = 0
        }
        if !transfer.task.isRecursive {
            transfer.task.sourceFingerprint = currentSource
        }

        let handle = try await client.open(
            path: resolvedDestination,
            flags: resumeOffset > 0 ? [.write, .create] : [.write, .create, .truncate],
            attributes: SFTPFileAttributes(permissions: 0o100644)
        )
        let input: TransferFileReader
        do {
            input = try TransferFileReader(url: localURL)
        } catch {
            try? await client.close(handle)
            throw error
        }

        do {
            var offset = UInt64(resumeOffset)
            if resumeOffset > 0 {
                try await input.seek(to: offset)
                reportRecoveredTransferProgress(transfer, transferID: transferID, bytes: resumeOffset)
            }
            while true {
                try Task.checkCancellation()
                let chunk = try await input.read(upToCount: 64 * 1024)
                if chunk.isEmpty { break }
                try await client.write(chunk, to: handle, offset: offset)
                offset += UInt64(chunk.count)
                updateTransferProgress(id: transferID, by: Int64(chunk.count))
            }
            try await client.close(handle)
            await input.close()
            try ensureLocalSourceIsUnchanged(currentSource, at: localURL)
            let completedBytes = try await existingRemoteFileSize(at: resolvedDestination, client: client)
            guard completedBytes == currentSource.size else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "The remote upload size did not match the source after transfer.",
                    korean: "업로드 후 원격 파일 크기가 원본과 일치하지 않습니다."
                ))
            }
        } catch {
            try? await client.close(handle)
            await input.close()
            throw error
        }
    }

    private func download(
        remotePath: String,
        to localURL: URL,
        transferID: UUID,
        client: SFTPClient
    ) async throws {
        do {
            try await downloadItem(remotePath: remotePath, to: localURL, transferID: transferID, client: client)
        } catch TransferConflictOutcome.skipItem {
            transfers[transferID]?.skippedItemCount += 1
        }
    }

    private func downloadItem(
        remotePath: String,
        to localURL: URL,
        transferID: UUID,
        client: SFTPClient
    ) async throws {
        try Task.checkCancellation()
        let source = try SFTPRemotePath(rawValue: remotePath)
        let attributes = try await client.attributes(of: source, followSymlink: false)
        let isRecursiveTransferRoot = transfers[transferID]?.task.isRecursive == true
            && remotePath == transfers[transferID]?.task.remotePath
        if isRemoteSymbolicLink(attributes) {
            let target = try await client.symbolicLinkTarget(at: source)
            let destination = try resolvedLocalDestination(localURL, isDirectory: false, transferID: transferID)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } else if isRemoteDirectory(attributes) {
            guard let transfer = transfers[transferID] else { throw CoreWorkspaceServiceError.transferNotFound }
            let key = RecursiveTransferResumeKey.remoteFile(at: source)
            let destination: URL
            if transfer.task.retryCount > 0,
               case let .localFile(saved)? = transfer.recursiveResumeLedger.directoryDestination(for: key) {
                destination = saved
                if localItemExists(destination) {
                    let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                            "The local folder changed before retry. Choose a new download destination.",
                            korean: "재시도 전에 로컬 폴더가 변경되었습니다. 새 다운로드 대상을 선택하세요."
                        ))
                    }
                }
            } else {
                destination = try resolvedLocalDestination(localURL, isDirectory: true, transferID: transferID)
                if isRecursiveTransferRoot {
                    transfers[transferID]?.task.localURL = destination
                }
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            transfer.recursiveResumeLedger.recordDirectory(.localFile(destination), for: key)
            let entries = try await client.listDirectory(source)
            for entry in entries where entry.filename != "." && entry.filename != ".." {
                try await download(
                    remotePath: joinRemotePath(remotePath, entry.filename),
                    to: destination.appendingPathComponent(entry.filename),
                    transferID: transferID,
                    client: client
                )
            }
        } else {
            try await downloadFile(source: source, to: localURL, transferID: transferID, client: client)
        }
    }

    private func downloadFile(
        source: SFTPRemotePath,
        to localURL: URL,
        transferID: UUID,
        client: SFTPClient
    ) async throws {
        guard let transfer = transfers[transferID] else { throw CoreWorkspaceServiceError.transferNotFound }
        let currentSource = try await remoteTransferFingerprint(at: source, client: client)
        let isRetryingSingleFile = !transfer.task.isRecursive
            && transfer.task.retryCount > 0
            && transfer.task.sourceFingerprint != nil
        let destination: URL
        let previousSource: TransferSourceFingerprint?
        let shouldAttemptResume: Bool
        if transfer.task.isRecursive {
            let resumeKey = RecursiveTransferResumeKey.remoteFile(at: source)
            if transfer.task.retryCount > 0,
               let checkpoint = transfer.recursiveResumeLedger.checkpoint(for: resumeKey) {
                guard case let .localFile(savedDestination) = checkpoint.destination else {
                    throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                        "The recursive download checkpoint has an invalid destination.",
                        korean: "재귀 다운로드 재개 기록의 대상이 올바르지 않습니다."
                    ))
                }
                destination = savedDestination
                previousSource = checkpoint.sourceFingerprint
                shouldAttemptResume = true
            } else {
                destination = try resolvedLocalDestination(localURL, isDirectory: false, transferID: transferID)
                previousSource = nil
                shouldAttemptResume = false
            }
            transfer.recursiveResumeLedger.record(
                RecursiveTransferResumeCheckpoint(
                    sourceFingerprint: currentSource,
                    destination: .localFile(destination)
                ),
                for: resumeKey
            )
        } else if isRetryingSingleFile {
            destination = localURL
            previousSource = transfer.task.sourceFingerprint
            shouldAttemptResume = true
        } else {
            destination = try resolvedLocalDestination(localURL, isDirectory: false, transferID: transferID)
            transfer.task.localURL = destination
            previousSource = nil
            shouldAttemptResume = false
        }
        let existingLocalBytes = try existingLocalFileSize(at: destination)
        let resumeDecision: TransferResumeDecision
        if shouldAttemptResume, let previousSource {
            resumeDecision = try await verifiedResumeDecision(
                localURL: destination,
                remotePath: source,
                existingDestinationBytes: existingLocalBytes,
                previousSource: previousSource,
                currentSource: currentSource,
                client: client
            )
        } else {
            resumeDecision = .restart
        }
        let resumeOffset: Int64
        switch resumeDecision {
        case let .resume(fromOffset):
            resumeOffset = fromOffset
        case .alreadyComplete:
            try await ensureRemoteSourceIsUnchanged(currentSource, at: source, client: client)
            reportRecoveredTransferProgress(transfer, transferID: transferID, bytes: currentSource.size)
            return
        case .restart:
            resumeOffset = 0
        }
        if !transfer.task.isRecursive {
            transfer.task.sourceFingerprint = currentSource
        }

        let handle = try await client.open(path: source, flags: [.read])
        let manager = FileManager.default
        let output: TransferFileWriter
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if resumeOffset == 0, manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            if !manager.fileExists(atPath: destination.path) {
                guard manager.createFile(atPath: destination.path, contents: nil) else {
                    throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                        "Could not create the local download destination.",
                        korean: "로컬 다운로드 대상을 만들 수 없습니다."
                    ))
                }
            }
            output = try TransferFileWriter(url: destination)
        } catch {
            try? await client.close(handle)
            throw error
        }

        do {
            var offset = UInt64(resumeOffset)
            if resumeOffset > 0 {
                try await output.seek(to: offset)
                reportRecoveredTransferProgress(transfer, transferID: transferID, bytes: resumeOffset)
            }
            while let chunk = try await client.read(from: handle, offset: offset, length: 64 * 1024) {
                try Task.checkCancellation()
                try await output.write(chunk)
                offset += UInt64(chunk.count)
                updateTransferProgress(id: transferID, by: Int64(chunk.count))
            }
            try await client.close(handle)
            await output.close()
            try await ensureRemoteSourceIsUnchanged(currentSource, at: source, client: client)
            let completedBytes = try existingLocalFileSize(at: destination)
            guard completedBytes == currentSource.size else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "The local download size did not match the source after transfer.",
                    korean: "다운로드 후 로컬 파일 크기가 원본과 일치하지 않습니다."
                ))
            }
        } catch {
            try? await client.close(handle)
            await output.close()
            throw error
        }
    }

    private func ensureRemoteDirectory(_ path: SFTPRemotePath, client: SFTPClient) async throws {
        do {
            let attributes = try await client.attributes(of: path, followSymlink: false)
            guard isRemoteDirectory(attributes) else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string("A remote file already uses this folder name.", korean: "같은 이름의 원격 파일이 이미 있습니다."))
            }
        } catch let error as SFTPClientError {
            guard case let .remoteStatus(_, status, _) = error, status == .noSuchFile else { throw error }
            try await client.makeDirectory(path)
        }
    }

    private func resolvedRemoteDestination(
        _ requested: SFTPRemotePath,
        transferID: UUID,
        client: SFTPClient
    ) async throws -> SFTPRemotePath {
        guard let task = transfers[transferID]?.task else { throw CoreWorkspaceServiceError.transferNotFound }
        do {
            _ = try await client.attributes(of: requested, followSymlink: false)
            switch task.conflictPolicy {
            case .overwrite:
                return requested
            case .skip:
                throw TransferConflictOutcome.skipItem
            case .rename:
                var ordinal = 1
                while true {
                    let candidate = try SFTPRemotePath(rawValue: remoteRenameCandidate(requested.rawValue, ordinal: ordinal))
                    do {
                        _ = try await client.attributes(of: candidate, followSymlink: false)
                        ordinal += 1
                    } catch let error as SFTPClientError {
                        if case let .remoteStatus(_, status, _) = error, status == .noSuchFile { return candidate }
                        throw error
                    }
                }
            case .ask:
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "Choose whether to overwrite, skip, or rename the existing remote item before uploading.",
                    korean: "원격 항목이 이미 있습니다. 업로드하기 전에 덮어쓰기, 건너뛰기 또는 이름 변경을 선택하세요."
                ))
            }
        } catch let error as SFTPClientError {
            if case let .remoteStatus(_, status, _) = error, status == .noSuchFile { return requested }
            throw error
        }
    }

    private func resolvedLocalDestination(_ url: URL, isDirectory: Bool, transferID: UUID) throws -> URL {
        guard let task = transfers[transferID]?.task else { throw CoreWorkspaceServiceError.transferNotFound }
        let manager = FileManager.default
        guard localItemExists(url) else {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        switch task.conflictPolicy {
        case .overwrite:
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if isDirectory, values.isDirectory == true, values.isSymbolicLink != true {
                // Merge directory contents. Removing the directory here would
                // delete unrelated local files before the transfer starts.
                return url
            }
            guard values.isDirectory != true || values.isSymbolicLink == true else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "A folder cannot be overwritten by a file. Choose a different name.",
                    korean: "폴더를 파일로 덮어쓸 수 없습니다. 다른 이름을 선택하세요."
                ))
            }
            try manager.removeItem(at: url)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        case .skip:
            throw TransferConflictOutcome.skipItem
        case .ask:
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Choose whether to overwrite, skip, or rename the existing local item before downloading.",
                korean: "로컬 항목이 이미 있습니다. 다운로드하기 전에 덮어쓰기, 건너뛰기 또는 이름 변경을 선택하세요."
            ))
        case .rename:
            var ordinal = 1
            while true {
                let candidate = try TransferPlanner.suggestedRename(for: url, ordinal: ordinal)
                if !localItemExists(candidate) {
                    try manager.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
                    return candidate
                }
                ordinal += 1
            }
        }
    }

    private func localItemExists(_ url: URL) -> Bool {
        // fileExists follows symlinks and misses dangling links, which still
        // occupy a filename and must participate in conflict resolution.
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func remoteRenameCandidate(_ path: String, ordinal: Int) -> String {
        let parent = remoteParent(path)
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let stem: String
        let suffix: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            suffix = String(name[dot...])
        } else {
            stem = name
            suffix = ""
        }
        return joinRemotePath(parent, "\(stem) (\(ordinal))\(suffix)")
    }

    private func recursiveLocalSize(at url: URL) throws -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, let size = values.fileSize { total += Int64(size) }
        }
        return total
    }

    private func localTransferFingerprint(at url: URL) throws -> TransferSourceFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile != false, let size = values.fileSize, size >= 0 else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Only regular files can be resumed.",
                korean: "일반 파일만 이어받을 수 있습니다."
            ))
        }
        return TransferSourceFingerprint(
            size: Int64(size),
            modificationTime: values.contentModificationDate
        )
    }

    private func remoteTransferFingerprint(
        at path: SFTPRemotePath,
        client: SFTPClient
    ) async throws -> TransferSourceFingerprint {
        let attributes = try await client.attributes(of: path, followSymlink: false)
        guard !isRemoteDirectory(attributes), !isRemoteSymbolicLink(attributes),
              let size = attributes.size, size <= UInt64(Int64.max)
        else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "Only regular remote files can be resumed.",
                korean: "일반 원격 파일만 이어받을 수 있습니다."
            ))
        }
        return TransferSourceFingerprint(
            size: Int64(size),
            modificationTime: attributes.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private func remoteEditFingerprint(
        at path: SFTPRemotePath,
        client: SFTPClient
    ) async throws -> RemoteEditSourceFingerprint {
        let metadata = try await remoteTransferFingerprint(at: path, client: client)
        let handle = try await client.open(path: path, flags: [.read])
        var hasher = SHA256()
        do {
            var offset: UInt64 = 0
            while let chunk = try await client.read(from: handle, offset: offset, length: 64 * 1024) {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                offset += UInt64(chunk.count)
            }
            try await client.close(handle)
        } catch {
            try? await client.close(handle)
            throw error
        }
        let metadataAfterRead = try await remoteTransferFingerprint(at: path, client: client)
        guard metadataAfterRead == metadata else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The remote file changed while its integrity check was running.",
                korean: "무결성 확인 중 원격 파일이 변경되었습니다."
            ))
        }
        return RemoteEditSourceFingerprint(metadata: metadataAfterRead, sha256: Data(hasher.finalize()))
    }

    private func existingRemoteFileSize(
        at path: SFTPRemotePath,
        client: SFTPClient
    ) async throws -> Int64 {
        do {
            let attributes = try await client.attributes(of: path, followSymlink: false)
            guard !isRemoteDirectory(attributes), !isRemoteSymbolicLink(attributes),
                  let size = attributes.size, size <= UInt64(Int64.max)
            else {
                throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                    "A non-file item already uses this remote name.",
                    korean: "같은 원격 이름을 파일이 아닌 항목이 사용하고 있습니다."
                ))
            }
            return Int64(size)
        } catch let error as SFTPClientError {
            if case let .remoteStatus(_, status, _) = error, status == .noSuchFile { return 0 }
            throw error
        }
    }

    private func existingLocalFileSize(at url: URL) throws -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return 0 }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false, let size = values.fileSize, size >= 0 else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The partial local destination is not a regular file.",
                korean: "부분 로컬 대상이 일반 파일이 아닙니다."
            ))
        }
        return Int64(size)
    }

    /// A resume decision is made only after the caller has compared source
    /// metadata and the complete destination prefix. A matching full-size
    /// prefix is also meaningful because it lets a retry keep a finished leaf.
    private func verifiedResumeDecision(
        localURL: URL,
        remotePath: SFTPRemotePath,
        existingDestinationBytes: Int64,
        previousSource: TransferSourceFingerprint,
        currentSource: TransferSourceFingerprint,
        client: SFTPClient
    ) async throws -> TransferResumeDecision {
        guard existingDestinationBytes > 0,
              existingDestinationBytes <= currentSource.size,
              previousSource == currentSource
        else {
            return .restart
        }
        let prefixDigestMatches = try await SFTPResumeIntegrityVerifier(client: client).localAndRemotePrefixMatch(
            localURL: localURL,
            remotePath: remotePath,
            byteCount: existingDestinationBytes
        )
        return TransferResumePlanner.decide(
            existingDestinationBytes: existingDestinationBytes,
            previousSource: previousSource,
            currentSource: currentSource,
            prefixDigestMatches: prefixDigestMatches
        )
    }

    private func ensureLocalSourceIsUnchanged(
        _ expected: TransferSourceFingerprint,
        at localURL: URL
    ) throws {
        guard try localTransferFingerprint(at: localURL) == expected else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The local source changed while it was being transferred. The retry will restart safely.",
                korean: "전송 중 로컬 원본이 변경되었습니다. 다시 시도하면 안전하게 처음부터 전송합니다."
            ))
        }
    }

    private func ensureRemoteSourceIsUnchanged(
        _ expected: TransferSourceFingerprint,
        at remotePath: SFTPRemotePath,
        client: SFTPClient
    ) async throws {
        guard try await remoteTransferFingerprint(at: remotePath, client: client) == expected else {
            throw CoreWorkspaceServiceError.invalidProfile(AppText.string(
                "The remote source changed while it was being transferred. The retry will restart safely.",
                korean: "전송 중 원격 원본이 변경되었습니다. 다시 시도하면 안전하게 처음부터 전송합니다."
            ))
        }
    }

    private func reportRecoveredTransferProgress(
        _ transfer: ManagedTransfer,
        transferID: UUID,
        bytes: Int64
    ) {
        if transfer.task.isRecursive {
            updateTransferProgress(id: transferID, by: bytes)
        } else {
            updateTransferProgress(id: transferID, to: bytes)
        }
    }

    private func makeRemoteEditURL(for remotePath: SFTPRemotePath) throws -> URL {
        let directory = storageDirectory.appendingPathComponent("editing", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let remoteName = remotePath.rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? "remote-file"
        return directory.appendingPathComponent("\(UUID().uuidString)-\(remoteName)", isDirectory: false)
    }

    private func updateTransferProgress(id: UUID, by delta: Int64) {
        guard let transfer = transfers[id], transfer.task.state == .running else { return }
        let bytes = transfer.task.bytesTransferred + delta
        transfer.task = (try? TransferTaskStateMachine.apply(
            .updateProgress(bytesTransferred: bytes, totalBytes: transfer.task.totalBytes),
            to: transfer.task
        )) ?? transfer.task
        emitSnapshot()
    }

    private func updateTransferProgress(id: UUID, to bytes: Int64) {
        guard let transfer = transfers[id], transfer.task.state == .running else { return }
        transfer.task = (try? TransferTaskStateMachine.apply(
            .updateProgress(bytesTransferred: bytes, totalBytes: transfer.task.totalBytes),
            to: transfer.task
        )) ?? transfer.task
        emitSnapshot()
    }

    // MARK: Tunnel process lifecycle

    private func launchTunnel(_ tunnel: ManagedTunnel, profile: ConnectionProfile) async throws {
        guard tunnel.rule.enabled else {
            throw CoreWorkspaceServiceError.invalidForwarding(AppText.string("This tunnel rule is disabled.", korean: "이 터널 규칙은 비활성화되어 있습니다."))
        }
        try tunnel.rule.validate()
        let route = try SSHRouteResolver.resolve(target: profile, profiles: profileDocument.profiles)
        let capabilities = try OpenSSHCapabilities.current()
        try capabilities.validate(route: route, forwardingRules: [tunnel.rule])

        cleanTunnelResources(tunnel)
        let challengeSessionID = tunnel.sessionID ?? selectedSessionID ?? UUID()
        let gate = CredentialChallengeGate(sessionID: challengeSessionID)
        let tunnelID = tunnel.id
        gate.presenter = { [weak self, weak gate] challenge in
            Task { @MainActor [weak self, weak gate] in
                guard let self, let gate else { return }
                self.challengeGates[challenge.id] = gate
                self.authenticationChallenge = challenge
                self.emitSnapshot()
            }
        }
        let broker = try makeCredentialBroker(route: route, gate: gate)
        do {
            let proxyHelper = try makeProxyHelperConfiguration(route: route, broker: broker, sessionID: tunnelID)
            let prepared = try OpenSSHCommandCompiler().prepare(
                route: route,
                knownHostsURL: knownHostsURL,
                proxyHelper: proxyHelper,
                hostKeyPolicy: .promptUser,
                purpose: .tunnel,
                forwardingRules: [tunnel.rule],
                baseDirectory: FileManager.default.temporaryDirectory
            )
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = prepared.invocation.executableURL
            process.arguments = prepared.invocation.arguments
            process.environment = processEnvironment(overrides: try askPassEnvironment(broker: broker))
            process.standardOutput = standardOutput
            process.standardError = standardError
            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
            standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in
                    self?.consumeTunnelOutput(id: tunnelID, text: text)
                }
            }
            process.terminationHandler = { [weak self] process in
                Task { @MainActor [weak self] in
                    self?.finishTunnel(id: tunnelID, status: process.terminationStatus)
                }
            }
            tunnel.process = process
            tunnel.preparedCommand = prepared
            tunnel.credentialBroker = broker
            tunnel.challengeGate = gate
            tunnel.userRequestedStop = false
            tunnel.phase = .starting
            tunnel.destinationReachability = .initial(for: tunnel.rule)
            do {
                try process.run()
            } catch {
                cleanTunnelResources(tunnel)
                throw error
            }
        } catch {
            broker.stop()
            throw error
        }
    }

    private func consumeTunnelOutput(id: UUID, text: String) {
        guard let tunnel = tunnels[id] else { return }
        let maximum = 64 * 1024
        let bytes = Data(text.utf8)
        if tunnel.stderrTail.count + bytes.count > maximum {
            tunnel.stderrTail = Data(tunnel.stderrTail.suffix(max(0, maximum - bytes.count)))
        }
        tunnel.stderrTail.append(bytes)

        for event in OpenSSHTunnelOutputParser.events(in: text, rules: [tunnel.rule]) {
            switch event {
            case let .listenerReady(_, assignedPort):
                tunnel.assignedPort = assignedPort ?? tunnel.rule.listenPort
                tunnel.destinationReachability = .initial(for: tunnel.rule)
                tunnel.phase = .listening
            case let .listenerFailed(_, message):
                tunnel.destinationReachability = .initial(for: tunnel.rule)
                tunnel.phase = .failed(OpenSSHOutputSanitizer.displayMessage(message))
            }
        }
        for event in OpenSSHOutputParser.events(in: text) {
            switch event {
            case .authenticationFailed:
                tunnel.phase = .failed(AppText.string("Tunnel authentication failed.", korean: "터널 인증에 실패했습니다."))
            case let .transportFailure(message):
                tunnel.phase = .failed(message)
            case .hostKeyChanged:
                tunnel.phase = .failed(AppText.string("The server host key changed. Review it in a terminal session before restarting this tunnel.", korean: "서버 호스트 키가 변경되었습니다. 터널을 다시 시작하기 전에 터미널 세션에서 검토하세요."))
            case .authenticated, .hostKeyRejected:
                break
            }
        }
        emitSnapshot()
    }

    private func finishTunnel(id: UUID, status: Int32) {
        guard let tunnel = tunnels[id] else { return }
        let stoppedByUser = tunnel.userRequestedStop
        let existingPhase = tunnel.phase
        cleanTunnelResources(tunnel)
        if stoppedByUser || status == 0 {
            tunnel.phase = .stopped
            tunnel.destinationReachability = .initial(for: tunnel.rule)
        } else if case .failed = existingPhase {
            tunnel.phase = existingPhase
            tunnel.destinationReachability = .initial(for: tunnel.rule)
        } else {
            tunnel.phase = .failed(AppText.string(
                "OpenSSH tunnel exited with status \(status).",
                korean: "OpenSSH 터널이 상태 \(status)로 종료되었습니다."
            ))
            tunnel.destinationReachability = .initial(for: tunnel.rule)
        }
        emitSnapshot()
    }

    private func destinationProbeMessage(for failure: TunnelDestinationProbeFailure) -> String {
        switch failure {
        case .invalidEndpoint:
            AppText.string(
                "The tunnel endpoint is invalid.",
                korean: "터널 endpoint가 올바르지 않습니다."
            )
        case .unavailable:
            AppText.string(
                "The destination is unavailable.",
                korean: "대상 서비스에 연결할 수 없습니다."
            )
        case .refused:
            AppText.string(
                "The destination refused the connection.",
                korean: "대상 서비스가 연결을 거부했습니다."
            )
        case .timedOut:
            AppText.string(
                "The destination probe timed out.",
                korean: "대상 확인 시간이 초과되었습니다."
            )
        }
    }

    private func cleanTunnelResources(_ tunnel: ManagedTunnel) {
        if let pipe = tunnel.process?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if let pipe = tunnel.process?.standardError as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        tunnel.process?.terminationHandler = nil
        tunnel.credentialBroker?.stop()
        tunnel.credentialBroker = nil
        tunnel.challengeGate?.cancelAll()
        tunnel.challengeGate = nil
        tunnel.preparedCommand?.configuration.cleanup()
        tunnel.preparedCommand = nil
        tunnel.process = nil
    }

    private func forwardingRule(from draft: ForwardingDraftPresentation) throws -> ForwardingRule {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CoreWorkspaceServiceError.invalidForwarding(AppText.string("Enter a tunnel name.", korean: "터널 이름을 입력하세요."))
        }
        let bindAddress = draft.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBindAddress = bindAddress.isEmpty ? "127.0.0.1" : bindAddress
        let isSocket = draft.direction == .localSocket || draft.direction == .remoteSocket
        let kind: ForwardingKind
        switch draft.direction {
        case .local: kind = .local
        case .remote: kind = .remote
        case .dynamic: kind = .dynamic
        case .remoteDynamic: kind = .remoteDynamic
        case .localSocket: kind = .localUnix
        case .remoteSocket: kind = .remoteUnix
        }
        if isSocket {
            let source = draft.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = draft.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            let rule = ForwardingRule(
                id: draft.id,
                name: name,
                kind: kind,
                bindAddress: "",
                listenPath: source,
                destinationPath: destination,
                exposeExternally: false
            )
            try rule.validate()
            return rule
        }
        guard let port = Int(draft.source.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CoreWorkspaceServiceError.invalidForwarding(AppText.string("Enter a valid listener port.", korean: "올바른 listener 포트를 입력하세요."))
        }
        let destination: (host: String, port: Int)?
        switch kind {
        case .local, .remote:
            destination = try parseHostPort(draft.destination)
        case .dynamic, .remoteDynamic, .localUnix, .remoteUnix:
            destination = nil
        }
        let rule = ForwardingRule(
            id: draft.id,
            name: name,
            kind: kind,
            bindAddress: resolvedBindAddress,
            listenPort: port,
            destinationHost: destination?.host,
            destinationPort: destination?.port,
            exposeExternally: !isLoopbackAddress(resolvedBindAddress)
        )
        try rule.validate()
        return rule
    }

    private func parseHostPort(_ rawValue: String) throws -> (host: String, port: Int) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let portText: String
        if value.hasPrefix("["), let close = value.lastIndex(of: "]") {
            let next = value.index(after: close)
            guard next < value.endIndex, value[next] == ":" else { throw CoreWorkspaceServiceError.invalidForwarding(AppText.string("Enter destination as host:port.", korean: "대상을 host:port 형식으로 입력하세요.")) }
            host = String(value[value.index(after: value.startIndex) ..< close])
            portText = String(value[value.index(after: next)...])
        } else if let separator = value.lastIndex(of: ":") {
            host = String(value[..<separator])
            portText = String(value[value.index(after: separator)...])
        } else {
            throw CoreWorkspaceServiceError.invalidForwarding(AppText.string("Enter destination as host:port.", korean: "대상을 host:port 형식으로 입력하세요."))
        }
        guard isValidEndpointHost(host), let port = Int(portText), (1 ... 65_535).contains(port) else {
            throw CoreWorkspaceServiceError.invalidForwarding(AppText.string("The destination host or port is invalid.", korean: "대상 호스트 또는 포트가 올바르지 않습니다."))
        }
        return (host, port)
    }

    private func forwardingDraft(_ rule: ForwardingRule) -> ForwardingDraftPresentation {
        ForwardingDraftPresentation(
            id: rule.id,
            name: rule.name,
            direction: tunnelDirection(rule.kind),
            bindAddress: rule.bindAddress,
            source: rule.listenPath ?? rule.listenPort.map(String.init) ?? "",
            destination: tunnelDestination(rule) ?? "",
            startIndependently: tunnels[rule.id]?.isIndependent ?? false
        )
    }

    private func tunnelDirection(_ kind: ForwardingKind) -> TunnelDirectionPresentation {
        switch kind {
        case .local: .local
        case .remote: .remote
        case .dynamic: .dynamic
        case .remoteDynamic: .remoteDynamic
        case .localUnix: .localSocket
        case .remoteUnix: .remoteSocket
        }
    }

    private func tunnelEndpoint(_ tunnel: ManagedTunnel) -> String? {
        if let path = tunnel.rule.listenPath { return path }
        guard let port = tunnel.assignedPort ?? tunnel.rule.listenPort else { return nil }
        return "\(tunnel.rule.bindAddress):\(port)"
    }

    private func tunnelDestination(_ rule: ForwardingRule) -> String? {
        if let path = rule.destinationPath { return path }
        guard let host = rule.destinationHost, let port = rule.destinationPort else { return nil }
        return "\(bracketedEndpointHost(host)):\(port)"
    }

    private func isLoopbackAddress(_ address: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(address.lowercased())
    }

    // MARK: Terminal evidence, prompts, and presentation conversion

    private func appendOutput(_ data: Data, to session: ManagedTerminalSession) {
        let maximum = 64 * 1024
        if session.outputTail.count + data.count > maximum {
            session.outputTail = Data(session.outputTail.suffix(max(0, maximum - data.count)))
        }
        session.outputTail.append(data)
        if session.descriptor.shouldLog {
            appendSessionLog(data, to: session)
        }
    }

    private func appendSessionLog(_ data: Data, to session: ManagedTerminalSession) {
        do {
            if session.logFile == nil {
                let directory = storageDirectory.appendingPathComponent("Logs", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let url = sessionLogURL(for: session.id)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                session.logFile = try FileHandle(forWritingTo: url)
                try session.logFile?.seekToEnd()
            }
            try session.logFile?.write(contentsOf: data)
        } catch {
            // Logging is opt-in and must not make a live terminal unusable.
            session.logFile?.closeFile()
            session.logFile = nil
        }
    }

    private func appendTerminalInputLog(
        _ data: Data,
        kind: String,
        to session: ManagedTerminalSession
    ) {
        guard session.descriptor.shouldLog, !data.isEmpty else { return }
        appendSessionLog(Data("[\(kind) \(Date())] ".utf8) + data, to: session)
    }

    private func sessionLogURL(for sessionID: UUID) -> URL {
        storageDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString.lowercased()).log", isDirectory: false)
    }

    private func enqueueTerminalInput(_ data: Data, to sessionID: UUID) {
        guard let session = sessions[sessionID], !data.isEmpty else { return }
        session.nextInputSequence &+= 1
        if session.nextInputSequence == 0 { session.nextInputSequence = 1 }
        session.pendingInput = TerminalInputPresentation(sequence: session.nextInputSequence, data: data)
    }

    private func presentChangedHostKeyChallenge(for session: ManagedTerminalSession) {
        guard !changedHostKeyChallenges.values.contains(session.id) else { return }
        let diagnostics = String(decoding: session.outputTail, as: UTF8.self)
        let fingerprint = OpenSSHHostKeyDiagnosticParser.fingerprint(in: diagnostics)
            ?? AppText.string("Fingerprint unavailable", korean: "fingerprint를 가져올 수 없음")
        let challenge = AuthenticationChallengePresentation(
            sessionID: session.id,
            prompt: AppText.string(
                "The saved server host key differs from the presented key. Review the fingerprint before replacing it.",
                korean: "저장된 서버 호스트 키와 제시된 키가 다릅니다. 교체하기 전에 fingerprint를 검토하세요."
            ),
            isSecure: false,
            attemptDescription: session.profileID.flatMap { id in
                profileDocument.profiles.first(where: { $0.id == id })
            }.map { "\($0.username)@\($0.host):\($0.port)" },
            kind: .hostKeyChanged(fingerprint: fingerprint)
        )
        changedHostKeyChallenges[challenge.id] = session.id
        authenticationChallenge = challenge
        session.state = .authenticating(AppText.string("Host key changed", korean: "호스트 키 변경됨"))
    }

    private func presentNewHostKeyFallbackChallenge(for session: ManagedTerminalSession) {
        guard !newHostKeyFallbackChallenges.values.contains(session.id) else { return }
        let diagnostics = String(decoding: session.outputTail, as: UTF8.self)
        let fingerprint = OpenSSHHostKeyDiagnosticParser.fingerprint(in: diagnostics)
            ?? AppText.string("Fingerprint unavailable", korean: "fingerprint를 가져올 수 없음")
        let challenge = AuthenticationChallengePresentation(
            sessionID: session.id,
            prompt: AppText.string(
                "The server key is not in this app's known hosts list. Reconnect to view and approve the presented key.",
                korean: "서버 키가 이 앱의 known hosts 목록에 없습니다. 다시 연결하여 제시된 키를 보고 승인하세요."
            ),
            isSecure: false,
            attemptDescription: session.profileID.flatMap { id in
                profileDocument.profiles.first(where: { $0.id == id })
            }.map { "\($0.username)@\($0.host):\($0.port)" },
            kind: .hostKeyNew(fingerprint: fingerprint)
        )
        newHostKeyFallbackChallenges[challenge.id] = session.id
        authenticationChallenge = challenge
        session.state = .authenticating(AppText.string("Host key review required", korean: "호스트 키 검토 필요"))
    }

    private func isTerminalFailure(_ state: SessionPresentationState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func transferPhase(_ state: TransferState, message: String?) -> TransferPhasePresentation {
        switch state {
        case .queued: .queued
        case .preparing: .preparing
        case .running, .cancelling: .transferring
        case .paused: .paused
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed(message ?? AppText.string("Transfer failed", korean: "전송 실패"))
        }
    }

    private func sshConfigImportPreview(
        result: SSHConfigImportResult,
        sourceURL: URL
    ) -> SSHConfigImportPreviewPresentation {
        SSHConfigImportPreviewPresentation(
            id: UUID(),
            sourcePath: sourceURL.path,
            profiles: result.profiles.map { imported in
                let authenticationSummary: String
                if !imported.identityFiles.isEmpty {
                    authenticationSummary = AppText.string("Private key", korean: "개인 키")
                } else if imported.identityAgent != nil {
                    authenticationSummary = AppText.string("SSH agent", korean: "SSH 에이전트")
                } else {
                    authenticationSummary = AppText.string("System SSH agent", korean: "시스템 SSH 에이전트")
                }
                return SSHConfigImportedProfilePresentation(
                    id: imported.id,
                    alias: imported.alias,
                    endpoint: "\(imported.username)@\(imported.host):\(imported.port)",
                    authenticationSummary: authenticationSummary,
                    jumpAliases: imported.proxyJump,
                    unsupportedDirectives: imported.unsupportedDirectives.map(\.keyword)
                )
            },
            diagnostics: result.diagnostics.map { diagnostic in
                SSHConfigImportDiagnosticPresentation(
                    id: UUID(),
                    severity: diagnostic.severity.rawValue,
                    message: diagnostic.message,
                    sourcePath: diagnostic.location.source?.path ?? sourceURL.path,
                    line: diagnostic.location.line
                )
            }
        )
    }

    private func settingsPresentation(from settings: AppSettings) -> AppSettingsPresentation {
        let appearance: AppSettingsPresentation.Appearance
        switch settings.appearance {
        case .system: appearance = .system
        case .light: appearance = .light
        case .dark: appearance = .dark
        }
        return AppSettingsPresentation(
            appearance: appearance,
            terminalFontName: TerminalFont(persistedName: settings.terminalFontName).rawValue,
            terminalFontSize: settings.terminalFontSize,
            terminalLineSpacing: settings.terminalLineSpacing,
            terminalThemeName: settings.terminalThemeName,
            allowRemoteClipboard: settings.allowRemoteClipboard,
            keepTunnelsRunningWhenWindowCloses: settings.keepTunnelsRunningWhenWindowCloses,
            sessionLoggingEnabled: settings.sessionLoggingEnabled
        )
    }

    private func appSettings(from presentation: AppSettingsPresentation) -> AppSettings {
        let appearance: AppAppearance
        switch presentation.appearance {
        case .system: appearance = .system
        case .light: appearance = .light
        case .dark: appearance = .dark
        }
        return AppSettings(
            appearance: appearance,
            terminalFontName: TerminalFont(persistedName: presentation.terminalFontName).rawValue,
            terminalFontSize: presentation.terminalFontSize,
            terminalLineSpacing: presentation.terminalLineSpacing,
            terminalThemeName: TerminalTheme(persistedName: presentation.terminalThemeName).rawValue,
            allowRemoteClipboard: presentation.allowRemoteClipboard,
            keepTunnelsRunningWhenWindowCloses: presentation.keepTunnelsRunningWhenWindowCloses,
            sessionLoggingEnabled: presentation.sessionLoggingEnabled
        )
    }

    private func proxyPresentation(_ kind: ProxyKind?) -> ProxyKindPresentation {
        switch kind {
        case .httpConnect: .httpConnect
        case .socks5: .socks5
        case nil: .none
        }
    }

    private func existingPasswordReference(_ authentication: AuthenticationMethod?) -> SecretReference? {
        guard case let .password(reference)? = authentication else { return nil }
        return reference
    }

    private func existingPassphraseReference(_ authentication: AuthenticationMethod?) -> SecretReference? {
        guard case let .privateKey(_, reference)? = authentication else { return nil }
        return reference
    }

    private func existingKeyboardInteractiveReference(_ authentication: AuthenticationMethod?) -> SecretReference? {
        guard case let .keyboardInteractive(reference)? = authentication else { return nil }
        return reference
    }

    private func positiveInterval(_ value: String, field: String) throws -> TimeInterval {
        guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite, parsed > 0, parsed.rounded() == parsed else {
            throw CoreWorkspaceServiceError.invalidProfile("\(field): \(AppText.string("enter a positive whole number.", korean: "양의 정수를 입력하세요."))")
        }
        return parsed
    }

    private func nonnegativeInterval(_ value: String, field: String) throws -> TimeInterval {
        guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite, parsed >= 0, parsed.rounded() == parsed else {
            throw CoreWorkspaceServiceError.invalidProfile("\(field): \(AppText.string("enter zero or a positive whole number.", korean: "0 또는 양의 정수를 입력하세요."))")
        }
        return parsed
    }

    private func optionalPath(_ value: String) -> String? {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\\0"), !path.contains("\n") else { return nil }
        return path
    }

    private func optionalText(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func isValidEndpointHost(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && value == host
            && !value.hasPrefix("-")
            && !value.contains("@")
            && !value.contains(",")
            && !value.contains("\\0")
    }

    private func bracketedEndpointHost(_ host: String) -> String {
        if host.hasPrefix("[") && host.hasSuffix("]") { return host }
        return host.contains(":") ? "[\(host)]" : host
    }
}

private struct ProfileExportDocument: Codable {
    let version: Int
    let generatedAt: Date
    let profiles: [ConnectionProfile]

    init(version: Int = 1, generatedAt: Date = .now, profiles: [ConnectionProfile]) {
        self.version = version
        self.generatedAt = generatedAt
        self.profiles = profiles
    }
}

private extension JSONEncoder {
    static var osXtermExport: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
