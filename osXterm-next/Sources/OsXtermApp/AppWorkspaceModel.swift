import AppKit
import Combine
import Foundation
import OsXtermCore

struct AppNotice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
final class AppWorkspaceModel: ObservableObject {
    @Published private(set) var snapshot: AppWorkspaceSnapshot
    @Published var sidebarSelection: AppSidebarSelection?
    @Published var inspectorSection: InspectorSection = .transfers
    @Published var isInspectorVisible = true
    @Published var profileEditorRequest: ProfileEditorRequest?
    @Published var tunnelEditorRequest: TunnelEditorRequest?
    @Published var sshConfigImportPreview: SSHConfigImportPreviewPresentation?
    @Published var isSettingsPresented = false
    @Published var notice: AppNotice?
    @Published private(set) var unavailableReason: String?

    private let service: any AppWorkspaceService

    init(service: (any AppWorkspaceService)? = nil) {
        self.service = service ?? UnconfiguredWorkspaceService()
        snapshot = .empty
        unavailableReason = self.service.isAvailable ? nil : self.service.unavailableReason

        self.service.setSnapshotHandler { [weak self] snapshot in
            self?.accept(snapshot)
        }

        if self.service.isAvailable {
            refresh()
        }
    }

    var isServiceAvailable: Bool { service.isAvailable }

    var hasActiveProcesses: Bool {
        snapshot.sessions.contains(where: { $0.state.isActive })
            || snapshot.tunnels.contains(where: { $0.phase == .starting || $0.phase == .listening || $0.phase == .stopping })
    }

    var selectedSession: TerminalSessionPresentation? {
        guard let selectedSessionID = snapshot.selectedSessionID else { return nil }
        return snapshot.sessions.first { $0.id == selectedSessionID }
    }

    func refresh() {
        guard service.isAvailable else {
            unavailableReason = service.unavailableReason ?? AppText.unavailable
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.service.loadSnapshot()
                self.accept(snapshot)
            } catch {
                self.present(error, title: AppText.string("Could not load workspace", korean: "작업 공간을 불러올 수 없습니다"))
            }
        }
    }

    func beginNewProfile() {
        profileEditorRequest = ProfileEditorRequest(mode: .create, draft: .blank())
    }

    func editProfile(id: UUID) {
        perform(
            title: AppText.string("Could not open profile", korean: "프로필을 열 수 없습니다"),
            refreshAfter: false
        ) { [weak self] in
            guard let self else { return }
            let draft = try await self.service.profileDraft(for: id)
            self.profileEditorRequest = ProfileEditorRequest(mode: .edit, draft: draft)
        }
    }

    func saveProfile(_ submission: ProfileEditorSubmission) {
        perform(title: AppText.string("Could not save profile", korean: "프로필을 저장할 수 없습니다")) { [service] in
            try await service.saveProfile(submission)
        }
        profileEditorRequest = nil
    }

    func connect(profileID: UUID) {
        perform(title: AppText.string("Could not connect", korean: "연결할 수 없습니다")) { [service] in
            try await service.connect(profileID: profileID)
        }
    }

    func startLocalTerminal() {
        perform(title: AppText.string("Could not start local terminal", korean: "로컬 터미널을 시작할 수 없습니다")) { [service] in
            try await service.startLocalTerminal()
        }
    }

    func disconnect(sessionID: UUID) {
        perform(title: AppText.string("Could not disconnect", korean: "연결을 종료할 수 없습니다")) { [service] in
            try await service.disconnect(sessionID: sessionID)
        }
    }

    func closeSession(id: UUID) {
        perform(title: AppText.string("Could not close tab", korean: "탭을 닫을 수 없습니다")) { [service] in
            try await service.closeSession(id: id)
        }
    }

    func selectSession(id: UUID?) {
        snapshot.selectedSessionID = id
        perform(title: AppText.string("Could not select session", korean: "세션을 선택할 수 없습니다"), refreshAfter: false) { [service] in
            try await service.selectSession(id: id)
        }
    }

    func setLayout(_ layout: WorkspaceLayoutPresentation) {
        perform(title: AppText.string("Could not update layout", korean: "레이아웃을 바꿀 수 없습니다")) { [service] in
            try await service.setWorkspaceLayout(layout)
        }
    }

    func renameSession(id: UUID, title: String) {
        perform(title: AppText.string("Could not rename tab", korean: "탭 이름을 바꿀 수 없습니다")) { [service] in
            try await service.renameSession(id: id, title: title)
        }
    }

    func duplicateSession(id: UUID) {
        perform(title: AppText.string("Could not duplicate tab", korean: "탭을 복제할 수 없습니다")) { [service] in
            try await service.duplicateSession(id: id)
        }
    }

    func moveSession(id: UUID, toIndex: Int) {
        perform(title: AppText.string("Could not reorder tabs", korean: "탭 순서를 바꿀 수 없습니다")) { [service] in
            try await service.moveSession(id: id, toIndex: toIndex)
        }
    }

    func duplicateProfile(id: UUID) {
        perform(title: AppText.string("Could not duplicate profile", korean: "프로필을 복제할 수 없습니다")) { [service] in
            try await service.duplicateProfile(id: id)
        }
    }

    func deleteProfile(id: UUID) {
        perform(title: AppText.string("Could not delete profile", korean: "프로필을 삭제할 수 없습니다")) { [service] in
            try await service.deleteProfile(id: id)
        }
    }

    func setFavorite(profileID: UUID, isFavorite: Bool) {
        perform(title: AppText.string("Could not update favorite", korean: "즐겨찾기를 변경할 수 없습니다")) { [service] in
            try await service.setFavorite(profileID: profileID, isFavorite: isFavorite)
        }
    }

    func saveFolder(id: UUID?, name: String) {
        perform(title: AppText.string("Could not save folder", korean: "폴더를 저장할 수 없습니다")) { [service] in
            try await service.saveFolder(id: id, name: name)
        }
    }

    func deleteFolder(id: UUID) {
        perform(title: AppText.string("Could not delete folder", korean: "폴더를 삭제할 수 없습니다")) { [service] in
            try await service.deleteFolder(id: id)
        }
    }

    func previewSSHConfig(from url: URL) {
        guard service.isAvailable else {
            unavailableReason = service.unavailableReason ?? AppText.unavailable
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.sshConfigImportPreview = try await self.service.previewSSHConfig(from: url)
            } catch {
                self.present(
                    error,
                    title: AppText.string("Could not preview SSH config", korean: "SSH 설정을 미리볼 수 없습니다")
                )
            }
        }
    }

    func importSSHConfig(previewID: UUID, profileIDs: Set<UUID>) {
        guard service.isAvailable else {
            unavailableReason = service.unavailableReason ?? AppText.unavailable
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service.importSSHConfig(previewID: previewID, profileIDs: profileIDs)
                if self.sshConfigImportPreview?.id == previewID {
                    self.sshConfigImportPreview = nil
                }
                self.accept(try await self.service.loadSnapshot())
            } catch {
                self.present(
                    error,
                    title: AppText.string("Could not import SSH config", korean: "SSH 설정을 가져올 수 없습니다")
                )
            }
        }
    }

    func discardSSHConfigImportPreview(id: UUID) {
        if sshConfigImportPreview?.id == id {
            sshConfigImportPreview = nil
        }
        Task { [service] in
            await service.discardSSHConfigImportPreview(id: id)
        }
    }

    func exportProfiles(ids: [UUID], to url: URL) {
        perform(title: AppText.string("Could not export profiles", korean: "프로필을 내보낼 수 없습니다"), refreshAfter: false) { [service] in
            try await service.exportProfiles(ids: ids, to: url)
        }
    }

    func exportSessionLog(sessionID: UUID, to url: URL) {
        perform(title: AppText.string("Could not export session log", korean: "세션 로그를 내보낼 수 없습니다"), refreshAfter: false) { [service] in
            try await service.exportSessionLog(sessionID: sessionID, to: url)
        }
    }

    func enqueueUpload(urls: [URL], to sessionID: UUID, conflictPolicy: TransferConflictPolicy = .rename) {
        perform(title: AppText.string("Could not queue upload", korean: "업로드를 대기열에 추가할 수 없습니다")) { [service] in
            try await service.enqueueUpload(urls: urls, to: sessionID, conflictPolicy: conflictPolicy)
        }
    }

    func enqueueSCPUpload(urls: [URL], to sessionID: UUID, conflictPolicy: TransferConflictPolicy = .rename) {
        perform(title: AppText.string("Could not queue SCP upload", korean: "SCP 업로드를 대기열에 추가할 수 없습니다")) { [service] in
            try await service.enqueueSCPUpload(urls: urls, to: sessionID, conflictPolicy: conflictPolicy)
        }
    }

    func enqueueDownload(transferID: UUID, to url: URL, conflictPolicy: TransferConflictPolicy = .rename) {
        perform(title: AppText.string("Could not queue download", korean: "다운로드를 대기열에 추가할 수 없습니다")) { [service] in
            try await service.enqueueDownload(transferID: transferID, to: url, conflictPolicy: conflictPolicy)
        }
    }

    func refreshRemoteFiles(sessionID: UUID) {
        perform(title: AppText.string("Could not refresh remote files", korean: "원격 파일을 새로 고칠 수 없습니다")) { [service] in
            try await service.refreshRemoteFiles(sessionID: sessionID)
        }
    }

    func navigateRemoteDirectory(path: String, sessionID: UUID) {
        perform(title: AppText.string("Could not open remote folder", korean: "원격 폴더를 열 수 없습니다")) { [service] in
            try await service.navigateRemoteDirectory(path: path, sessionID: sessionID)
        }
    }

    func createRemoteDirectory(name: String, sessionID: UUID) {
        perform(title: AppText.string("Could not create remote folder", korean: "원격 폴더를 만들 수 없습니다")) { [service] in
            try await service.createRemoteDirectory(name: name, sessionID: sessionID)
        }
    }

    func renameRemoteFile(path: String, to name: String, sessionID: UUID) {
        perform(title: AppText.string("Could not rename remote item", korean: "원격 항목의 이름을 바꿀 수 없습니다")) { [service] in
            try await service.renameRemoteFile(path: path, to: name, sessionID: sessionID)
        }
    }

    func deleteRemoteFile(path: String, sessionID: UUID) {
        perform(title: AppText.string("Could not delete remote item", korean: "원격 항목을 삭제할 수 없습니다")) { [service] in
            try await service.deleteRemoteFile(path: path, sessionID: sessionID)
        }
    }

    func changeRemotePermissions(path: String, permissions: String, sessionID: UUID) {
        perform(title: AppText.string("Could not change remote permissions", korean: "원격 권한을 바꿀 수 없습니다")) { [service] in
            try await service.changeRemotePermissions(path: path, permissions: permissions, sessionID: sessionID)
        }
    }

    func downloadRemoteFile(path: String, to url: URL, sessionID: UUID, conflictPolicy: TransferConflictPolicy = .rename) {
        perform(title: AppText.string("Could not download remote item", korean: "원격 항목을 다운로드할 수 없습니다")) { [service] in
            try await service.downloadRemoteFile(path: path, to: url, sessionID: sessionID, conflictPolicy: conflictPolicy)
        }
    }

    func downloadRemoteFileViaSCP(path: String, to url: URL, sessionID: UUID, conflictPolicy: TransferConflictPolicy = .rename) {
        perform(title: AppText.string("Could not download with SCP", korean: "SCP로 다운로드할 수 없습니다")) { [service] in
            try await service.downloadRemoteFileViaSCP(path: path, to: url, sessionID: sessionID, conflictPolicy: conflictPolicy)
        }
    }

    func openRemoteFileForEditing(path: String, sessionID: UUID) {
        guard service.isAvailable else {
            unavailableReason = service.unavailableReason ?? AppText.unavailable
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let edit = try await self.service.openRemoteFileForEditing(path: path, sessionID: sessionID)
                self.accept(try await self.service.loadSnapshot())
                if !NSWorkspace.shared.open(edit.localURL) {
                    self.present(
                        CoreWorkspaceServiceError.invalidProfile(AppText.string(
                            "The local editor could not open the working copy.",
                            korean: "로컬 편집기에서 작업 사본을 열 수 없습니다."
                        )),
                        title: AppText.string("Could not open editor", korean: "편집기를 열 수 없습니다")
                    )
                }
            } catch {
                self.present(error, title: AppText.string("Could not open remote file", korean: "원격 파일을 열 수 없습니다"))
            }
        }
    }

    func saveEditedRemoteFile(id: UUID) {
        perform(title: AppText.string("Could not save to remote", korean: "원격에 저장할 수 없습니다")) { [service] in
            try await service.saveEditedRemoteFile(id: id)
        }
    }

    func discardEditedRemoteFile(id: UUID) {
        perform(title: AppText.string("Could not discard working copy", korean: "작업 사본을 버릴 수 없습니다")) { [service] in
            try await service.discardEditedRemoteFile(id: id)
        }
    }

    func cancelTransfer(id: UUID) {
        perform(title: AppText.string("Could not cancel transfer", korean: "전송을 취소할 수 없습니다")) { [service] in
            try await service.cancelTransfer(id: id)
        }
    }

    func retryTransfer(id: UUID) {
        perform(title: AppText.string("Could not retry transfer", korean: "전송을 다시 시도할 수 없습니다")) { [service] in
            try await service.retryTransfer(id: id)
        }
    }

    func beginNewTunnel(for sessionID: UUID?) {
        tunnelEditorRequest = TunnelEditorRequest(existing: nil, sessionID: sessionID)
    }

    func editTunnel(_ tunnel: TunnelPresentation) {
        let draft = ForwardingDraftPresentation(
            id: tunnel.id,
            name: tunnel.name,
            direction: tunnel.direction,
            bindAddress: tunnel.bindAddress,
            source: tunnel.listeningEndpoint ?? "",
            destination: tunnel.destination ?? "",
            startIndependently: tunnel.isIndependent
        )
        tunnelEditorRequest = TunnelEditorRequest(existing: draft, sessionID: tunnel.sessionID)
    }

    func saveTunnel(_ draft: ForwardingDraftPresentation, sessionID: UUID?) {
        perform(title: AppText.string("Could not save tunnel", korean: "터널을 저장할 수 없습니다")) { [service] in
            try await service.saveTunnel(draft, sessionID: sessionID)
        }
        tunnelEditorRequest = nil
    }

    func deleteTunnel(id: UUID) {
        perform(title: AppText.string("Could not delete tunnel", korean: "터널을 삭제할 수 없습니다")) { [service] in
            try await service.deleteTunnel(id: id)
        }
    }

    func startTunnel(id: UUID) {
        perform(title: AppText.string("Could not start tunnel", korean: "터널을 시작할 수 없습니다")) { [service] in
            try await service.startTunnel(id: id)
        }
    }

    func stopTunnel(id: UUID) {
        perform(title: AppText.string("Could not stop tunnel", korean: "터널을 중지할 수 없습니다")) { [service] in
            try await service.stopTunnel(id: id)
        }
    }

    func restartTunnel(id: UUID) {
        perform(title: AppText.string("Could not restart tunnel", korean: "터널을 다시 시작할 수 없습니다")) { [service] in
            try await service.restartTunnel(id: id)
        }
    }

    func probeTunnelDestination(id: UUID) {
        perform(title: AppText.string("Could not test tunnel destination", korean: "터널 대상에 연결할 수 없습니다")) { [service] in
            try await service.probeTunnelDestination(id: id)
        }
    }

    func runSnippet(id: UUID, on sessionIDs: Set<UUID>, values: [UUID: String] = [:]) {
        perform(title: AppText.string("Could not run snippet", korean: "스니펫을 실행할 수 없습니다")) { [service] in
            try await service.runSnippet(id: id, on: sessionIDs, values: values)
        }
    }

    func saveSnippet(title: String, commandsText: String) {
        perform(title: AppText.string("Could not save snippet", korean: "스니펫을 저장할 수 없습니다")) { [service] in
            try await service.saveSnippet(title: title, commandsText: commandsText)
        }
    }

    func updateSnippet(id: UUID, title: String, commandsText: String) {
        perform(title: AppText.string("Could not update snippet", korean: "스니펫을 수정할 수 없습니다")) { [service] in
            try await service.updateSnippet(id: id, title: title, commandsText: commandsText)
        }
    }

    func deleteSnippet(id: UUID) {
        perform(title: AppText.string("Could not delete snippet", korean: "스니펫을 삭제할 수 없습니다")) { [service] in
            try await service.deleteSnippet(id: id)
        }
    }

    func setBroadcastTargets(_ sessionIDs: Set<UUID>) {
        perform(title: AppText.string("Could not update broadcast", korean: "동시 입력 대상을 변경할 수 없습니다")) { [service] in
            try await service.setBroadcastTargets(sessionIDs)
        }
    }

    func terminalInputDidSend(_ data: Data, from sessionID: UUID) {
        guard service.isAvailable, !data.isEmpty else { return }
        perform(title: AppText.string("Could not record terminal input", korean: "터미널 입력을 기록할 수 없습니다"), refreshAfter: false, presentsErrors: false) { [service] in
            try await service.terminalInputDidSend(data, from: sessionID)
        }
    }

    func terminalDidResize(sessionID: UUID, columns: Int, rows: Int) {
        guard service.isAvailable else { return }
        perform(title: AppText.string("Could not resize terminal", korean: "터미널 크기를 바꿀 수 없습니다"), refreshAfter: false, presentsErrors: false) { [service] in
            try await service.terminalDidResize(sessionID: sessionID, columns: columns, rows: rows)
        }
    }

    func terminalProcessDidStart(sessionID: UUID, launchID: UUID) {
        perform(title: AppText.string("Could not register terminal process", korean: "터미널 프로세스를 등록할 수 없습니다"), refreshAfter: true) { [service] in
            try await service.terminalProcessDidStart(sessionID: sessionID, launchID: launchID)
        }
    }

    func terminalProcessDidTerminate(sessionID: UUID, launchID: UUID, exitCode: Int32?) {
        perform(title: AppText.string("Could not record terminal exit", korean: "터미널 종료를 기록할 수 없습니다"), refreshAfter: true) { [service] in
            try await service.terminalProcessDidTerminate(sessionID: sessionID, launchID: launchID, exitCode: exitCode)
        }
    }

    func terminalProcessDidOutput(sessionID: UUID, launchID: UUID, data: Data) {
        guard service.isAvailable, !data.isEmpty else { return }
        perform(title: AppText.string("Could not process terminal output", korean: "터미널 출력을 처리할 수 없습니다"), refreshAfter: false, presentsErrors: false) { [service] in
            try await service.terminalProcessDidOutput(sessionID: sessionID, launchID: launchID, data: data)
        }
    }

    func updateSettings(_ settings: AppSettingsPresentation) {
        perform(title: AppText.string("Could not save settings", korean: "설정을 저장할 수 없습니다")) { [service] in
            try await service.updateSettings(settings)
        }
    }

    func respond(to challenge: AuthenticationChallengePresentation, response: String?) {
        perform(title: AppText.string("Could not complete authentication", korean: "인증을 완료할 수 없습니다")) { [service] in
            try await service.respond(to: challenge.id, response: response)
        }
    }

    func shutdownForTermination() {
        service.shutdown()
    }

    private func accept(_ snapshot: AppWorkspaceSnapshot) {
        self.snapshot = snapshot
        unavailableReason = nil
    }

    private func perform(
        title: String,
        refreshAfter: Bool = true,
        presentsErrors: Bool = true,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        guard service.isAvailable else {
            unavailableReason = service.unavailableReason ?? AppText.unavailable
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                if refreshAfter {
                    let snapshot = try await self.service.loadSnapshot()
                    self.accept(snapshot)
                }
            } catch {
                if presentsErrors {
                    self.present(error, title: title)
                }
            }
        }
    }

    private func present(_ error: Error, title: String) {
        notice = AppNotice(title: title, message: error.localizedDescription)
    }
}
