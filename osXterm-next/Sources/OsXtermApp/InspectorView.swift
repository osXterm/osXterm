import AppKit
import OsXtermCore
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            Picker(AppText.string("Inspector", korean: "검사기"), selection: $model.inspectorSection) {
                Label(AppText.transfers, systemImage: "arrow.up.arrow.down").tag(InspectorSection.transfers)
                Label(AppText.tunnels, systemImage: "arrow.left.arrow.right").tag(InspectorSection.tunnels)
                Label(AppText.connection, systemImage: "network").tag(InspectorSection.connection)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(10)
            Divider()

            Group {
                switch model.inspectorSection {
                case .transfers:
                    TransferInspector(model: model)
                case .tunnels:
                    TunnelInspector(model: model)
                case .connection:
                    ConnectionInspector(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
        .accessibilityLabel(AppText.string("Inspector", korean: "검사기"))
    }
}

private struct TransferInspector: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var isDropTarget = false
    @State private var isNewFolderPresented = false
    @State private var folderName = ""
    @State private var renameTarget: RemoteFilePresentation?
    @State private var renamedValue = ""
    @State private var permissionsTarget: RemoteFilePresentation?
    @State private var permissionsValue = ""
    @State private var deleteTarget: RemoteFilePresentation?
    @State private var showHiddenFiles = false
    @State private var transferConflictPolicy: TransferConflictPolicy = .rename
    @State private var remotePathInput = ""
    @FocusState private var isRemotePathFocused: Bool

    private var selectedSession: TerminalSessionPresentation? {
        model.selectedSession
    }

    private var isRemoteBrowserAvailable: Bool {
        guard let selectedSession else { return false }
        return selectedSession.supportsFileTransfer && selectedSession.state.isInputReady
    }

    private var visibleRemoteFiles: [RemoteFilePresentation] {
        showHiddenFiles
            ? model.snapshot.remoteFiles
            : model.snapshot.remoteFiles.filter { !$0.name.hasPrefix(".") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                remoteFileSection
                if !model.snapshot.remoteEdits.isEmpty {
                    Divider()
                    remoteEditSection
                }
                Divider()
                transferQueueSection
            }
            .padding(12)
        }
        .onAppear(perform: synchronizeRemotePathInput)
        .onChange(of: model.snapshot.remoteDirectoryPath) { _, _ in
            synchronizeRemotePathInput()
        }
        .onChange(of: selectedSession?.id) { _, _ in
            synchronizeRemotePathInput()
        }
        .sheet(isPresented: $isNewFolderPresented) {
            RemoteFolderNameSheet(
                title: AppText.string("New Remote Folder", korean: "새 원격 폴더"),
                name: $folderName,
                confirmTitle: AppText.string("Create", korean: "만들기"),
                onConfirm: createFolder
            )
        }
        .sheet(item: $renameTarget) { item in
            RemoteFolderNameSheet(
                title: AppText.string("Rename Remote Item", korean: "원격 항목 이름 바꾸기"),
                name: $renamedValue,
                confirmTitle: AppText.string("Rename", korean: "이름 바꾸기"),
                onConfirm: {
                    guard let session = selectedSession, let target = renameTarget else { return }
                    model.renameRemoteFile(path: target.absolutePath, to: renamedValue, sessionID: session.id)
                    renameTarget = nil
                    renamedValue = ""
                }
            )
        }
        .sheet(item: $permissionsTarget) { item in
            RemoteFolderNameSheet(
                title: AppText.string("Change Permissions", korean: "권한 변경"),
                name: $permissionsValue,
                confirmTitle: AppText.save,
                onConfirm: {
                    guard let session = selectedSession, let target = permissionsTarget else { return }
                    model.changeRemotePermissions(path: target.absolutePath, permissions: permissionsValue, sessionID: session.id)
                    permissionsTarget = nil
                    permissionsValue = ""
                }
            )
        }
        .confirmationDialog(
            AppText.string("Delete remote item?", korean: "원격 항목을 삭제할까요?"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { item in
            Button(AppText.delete, role: .destructive) {
                if let session = selectedSession {
                    model.deleteRemoteFile(path: item.absolutePath, sessionID: session.id)
                }
                deleteTarget = nil
            }
            Button(AppText.cancel, role: .cancel) { deleteTarget = nil }
        } message: { item in
            Text(AppText.string(
                "This removes \(item.name) from the remote server.",
                korean: "원격 서버에서 \(item.name)을 삭제합니다."
            ))
        }
    }

    @ViewBuilder
    private var remoteFileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppText.string("Remote Files", korean: "원격 파일"), systemImage: "folder")
                    .font(.headline)
                Spacer()
                Button {
                    if let session = selectedSession { model.refreshRemoteFiles(sessionID: session.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(AppText.string("Refresh remote files", korean: "원격 파일 새로 고침"))
                .disabled(!isRemoteBrowserAvailable || !model.isServiceAvailable)

                Menu {
                    Button(AppText.string("New Folder", korean: "새 폴더")) {
                        folderName = ""
                        isNewFolderPresented = true
                    }
                    .disabled(!isRemoteBrowserAvailable || !model.isServiceAvailable)
                    Button(AppText.string("Upload Files…", korean: "파일 업로드…")) {
                        chooseUploads()
                    }
                    .disabled(!isRemoteBrowserAvailable || !model.isServiceAvailable)
                    Button(AppText.string("Upload with SCP…", korean: "SCP로 업로드…")) {
                        chooseUploads(usingSCP: true)
                    }
                    .disabled(!isRemoteBrowserAvailable || !model.isServiceAvailable)
                    Divider()
                    Picker(
                        AppText.string("When a file exists", korean: "같은 이름의 파일이 있을 때"),
                        selection: $transferConflictPolicy
                    ) {
                        Text(AppText.string("Rename", korean: "이름 변경")).tag(TransferConflictPolicy.rename)
                        Text(AppText.string("Overwrite", korean: "덮어쓰기")).tag(TransferConflictPolicy.overwrite)
                        Text(AppText.string("Skip", korean: "건너뛰기")).tag(TransferConflictPolicy.skip)
                    }
                    Toggle(AppText.string("Show Hidden Files", korean: "숨김 파일 표시"), isOn: $showHiddenFiles)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(AppText.string("Remote file actions", korean: "원격 파일 작업"))
            }

            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    AppText.string("Remote Path", korean: "원격 경로"),
                    text: $remotePathInput,
                    prompt: Text(AppText.string("Remote path", korean: "원격 경로"))
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .focused($isRemotePathFocused)
                .onSubmit(navigateToEnteredPath)
                .accessibilityLabel(AppText.string("Remote path", korean: "원격 경로"))
                .accessibilityHint(AppText.string(
                    "Enter an SFTP directory path and press Return to open it.",
                    korean: "SFTP 디렉터리 경로를 입력하고 Return을 눌러 여세요."
                ))

                Button(action: navigateToEnteredPath) {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(AppText.string("Open remote path", korean: "원격 경로 열기"))
                .disabled(!isRemoteBrowserAvailable || !model.isServiceAvailable || remotePathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .disabled(!isRemoteBrowserAvailable || !model.isServiceAvailable)

            if let path = model.snapshot.remoteDirectoryPath, !path.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Button {
                        navigateUp(from: path)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppText.string("Parent folder", korean: "상위 폴더"))
                    .disabled(!isRemoteBrowserAvailable || path == "/")
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if !isRemoteBrowserAvailable {
                InspectorHint(
                    icon: "externaldrive.badge.xmark",
                    text: AppText.string(
                        "Connect an SSH session with SFTP support to browse remote files.",
                        korean: "원격 파일을 보려면 SFTP를 지원하는 SSH 세션에 연결하세요."
                    )
                )
            } else if visibleRemoteFiles.isEmpty {
                FileDropZone(isTargeted: $isDropTarget, onChoose: { chooseUploads() })
                    .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: receiveDrop)
            } else {
                VStack(spacing: 2) {
                    ForEach(visibleRemoteFiles) { item in
                        RemoteFileRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if item.isDirectory, let session = selectedSession {
                                    model.navigateRemoteDirectory(path: item.absolutePath, sessionID: session.id)
                                }
                            }
                            .contextMenu {
                                if item.isDirectory {
                                    Button(AppText.string("Open", korean: "열기")) {
                                        if let session = selectedSession {
                                            model.navigateRemoteDirectory(path: item.absolutePath, sessionID: session.id)
                                        }
                                    }
                                }
                                Button(AppText.string("Download…", korean: "다운로드…")) {
                                    chooseDownload(for: item)
                                }
                                Button(AppText.string("Download with SCP…", korean: "SCP로 다운로드…")) {
                                    chooseDownload(for: item, usingSCP: true)
                                }
                                if case .file = item.kind {
                                    Button(AppText.string("Open in Local Editor…", korean: "로컬 편집기로 열기…")) {
                                        if let session = selectedSession {
                                            model.openRemoteFileForEditing(path: item.absolutePath, sessionID: session.id)
                                        }
                                    }
                                }
                                Button(AppText.string("Rename…", korean: "이름 바꾸기…")) {
                                    renamedValue = item.name
                                    renameTarget = item
                                }
                                Button(AppText.string("Permissions…", korean: "권한…")) {
                                    permissionsValue = item.permissions ?? ""
                                    permissionsTarget = item
                                }
                                Divider()
                                Button(AppText.delete, role: .destructive) {
                                    deleteTarget = item
                                }
                            }
                    }
                }
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: receiveDrop)
            }
        }
    }

    private var transferQueueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppText.string("Transfer Queue", korean: "전송 대기열"), systemImage: "arrow.up.arrow.down")
                    .font(.headline)
                Spacer()
                Text(AppText.plural(
                    "1 transfer",
                    englishPlural: "\(model.snapshot.transfers.count) transfers",
                    korean: "전송 \(model.snapshot.transfers.count)개",
                    count: model.snapshot.transfers.count
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if model.snapshot.transfers.isEmpty {
                InspectorHint(
                    icon: "tray",
                    text: AppText.string("Queued uploads and downloads appear here.", korean: "대기 중인 업로드와 다운로드가 여기에 표시됩니다.")
                )
            } else {
                ForEach(model.snapshot.transfers) { transfer in
                    TransferRow(transfer: transfer, model: model)
                }
            }
        }
    }

    private var remoteEditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AppText.string("Local Editing Copies", korean: "로컬 편집 사본"), systemImage: "square.and.pencil")
                .font(.headline)
            Text(AppText.string(
                "Editor saves stay local. Select Save to Remote for each working copy when you are ready.",
                korean: "편집기에서 저장한 내용은 로컬에만 남습니다. 준비가 되면 각 작업 사본에서 원격에 저장을 선택하세요."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(model.snapshot.remoteEdits) { edit in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(edit.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(edit.remotePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(AppText.string("Open", korean: "열기")) {
                        NSWorkspace.shared.open(edit.localURL)
                    }
                    .buttonStyle(.borderless)
                    Button(AppText.string("Save to Remote", korean: "원격에 저장")) {
                        model.saveEditedRemoteFile(id: edit.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isServiceAvailable)
                    Menu {
                        Button(AppText.string("Show in Finder", korean: "Finder에서 보기")) {
                            NSWorkspace.shared.activateFileViewerSelecting([edit.localURL])
                        }
                        Divider()
                        Button(AppText.string("Discard Local Copy", korean: "로컬 사본 버리기"), role: .destructive) {
                            model.discardEditedRemoteFile(id: edit.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(AppText.string("Working copy actions", korean: "작업 사본 작업"))
                }
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let session = selectedSession, isRemoteBrowserAvailable, model.isServiceAvailable else { return false }
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        model.enqueueUpload(urls: [url], to: session.id, conflictPolicy: transferConflictPolicy)
                    }
                }
            }
        }
        return accepted
    }

    private func chooseUploads(usingSCP: Bool = false) {
        guard let session = selectedSession else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = AppText.string("Choose files or folders to upload.", korean: "업로드할 파일 또는 폴더를 선택하세요.")
        if panel.runModal() == .OK {
            if usingSCP {
                model.enqueueSCPUpload(urls: panel.urls, to: session.id, conflictPolicy: transferConflictPolicy)
            } else {
                model.enqueueUpload(urls: panel.urls, to: session.id, conflictPolicy: transferConflictPolicy)
            }
        }
    }

    private func chooseDownload(for item: RemoteFilePresentation, usingSCP: Bool = false) {
        guard let session = selectedSession else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.message = AppText.string("Choose where to save the remote item.", korean: "원격 항목을 저장할 위치를 선택하세요.")
        if panel.runModal() == .OK, let url = panel.url {
            if usingSCP {
                model.downloadRemoteFileViaSCP(
                    path: item.absolutePath,
                    to: url,
                    sessionID: session.id,
                    conflictPolicy: transferConflictPolicy
                )
            } else {
                model.downloadRemoteFile(
                    path: item.absolutePath,
                    to: url,
                    sessionID: session.id,
                    conflictPolicy: transferConflictPolicy
                )
            }
        }
    }

    private func createFolder() {
        guard let session = selectedSession else { return }
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.createRemoteDirectory(name: name, sessionID: session.id)
        folderName = ""
        isNewFolderPresented = false
    }

    private func navigateUp(from path: String) {
        guard let session = selectedSession else { return }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let parent = components.dropLast().joined(separator: "/")
        let parentPath = parent.isEmpty ? "/" : "/\(parent)"
        model.navigateRemoteDirectory(path: parentPath, sessionID: session.id)
    }

    private func navigateToEnteredPath() {
        guard let session = selectedSession,
              isRemoteBrowserAvailable,
              model.isServiceAvailable
        else {
            return
        }
        let path = remotePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            synchronizeRemotePathInput()
            return
        }
        model.navigateRemoteDirectory(path: path, sessionID: session.id)
        isRemotePathFocused = false
    }

    private func synchronizeRemotePathInput() {
        guard !isRemotePathFocused else { return }
        remotePathInput = model.snapshot.remoteDirectoryPath ?? ""
    }
}

private struct FileDropZone: View {
    @Binding var isTargeted: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.title3)
            Text(AppText.string("Drop files here to upload", korean: "업로드할 파일을 여기에 놓으세요"))
                .font(.callout.weight(.medium))
            Button(AppText.string("Choose Files…", korean: "파일 선택…"), action: onChoose)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 116)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [5]))
        }
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(AppText.string("Upload drop zone", korean: "업로드 드롭 영역"))
    }
}

private struct RemoteFileRow: View {
    let item: RemoteFilePresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(metadata)")
    }

    private var iconName: String {
        switch item.kind {
        case .directory: "folder.fill"
        case .file: "doc"
        case .symbolicLink: "arrow.triangle.branch"
        }
    }

    private var metadata: String {
        var values: [String] = []
        if let size = item.size {
            values.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let permissions = item.permissions, !permissions.isEmpty {
            values.append(permissions)
        }
        if case let .symbolicLink(target) = item.kind, let target, !target.isEmpty {
            values.append("→ \(target)")
        }
        return values.isEmpty
            ? (item.isDirectory ? AppText.string("Folder", korean: "폴더") : AppText.string("File", korean: "파일"))
            : values.joined(separator: "  ")
    }
}

private struct TransferRow: View {
    let transfer: TransferPresentation
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(transfer.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                TransferPhaseLabel(phase: transfer.phase)
            }
            Text("\(transfer.sourceDescription) → \(transfer.destinationDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let progress = transfer.progress {
                ProgressView(value: progress)
                Text(progressDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !transfer.phase.isTerminal {
                ProgressView()
                    .controlSize(.small)
            }
            HStack {
                Spacer()
                switch transfer.phase {
                case .queued, .preparing, .transferring, .paused:
                    Button(AppText.cancel) { model.cancelTransfer(id: transfer.id) }
                        .buttonStyle(.borderless)
                case .failed:
                    Button(AppText.string("Retry", korean: "다시 시도")) { model.retryTransfer(id: transfer.id) }
                        .buttonStyle(.borderless)
                case .completed, .cancelled:
                    EmptyView()
                }
            }
        }
        .padding(9)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var progressDescription: String {
        let transferred = ByteCountFormatter.string(fromByteCount: transfer.bytesTransferred, countStyle: .file)
        if let total = transfer.totalBytes {
            return "\(transferred) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return transferred
    }
}

private struct TransferPhaseLabel: View {
    let phase: TransferPhasePresentation

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var title: String {
        switch phase {
        case .queued: AppText.string("Queued", korean: "대기")
        case .preparing: AppText.string("Preparing", korean: "준비 중")
        case .transferring: AppText.string("Transferring", korean: "전송 중")
        case .paused: AppText.string("Paused", korean: "일시 중지")
        case .completed: AppText.string("Complete", korean: "완료")
        case .failed: AppText.string("Failed", korean: "실패")
        case .cancelled: AppText.string("Cancelled", korean: "취소됨")
        }
    }

    private var color: Color {
        switch phase {
        case .completed: .green
        case .failed: .red
        case .transferring, .preparing: .accentColor
        case .queued, .paused, .cancelled: .secondary
        }
    }
}

private struct TunnelInspector: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var tunnelPendingDeletion: TunnelPresentation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(AppText.tunnels, systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.beginNewTunnel(for: model.selectedSession?.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppText.string("New tunnel", korean: "새 터널"))
                    .disabled(!model.isServiceAvailable)
                }

                Text(AppText.string(
                    "Loopback is the default bind address. Public exposure must be selected explicitly.",
                    korean: "기본 바인드 주소는 loopback입니다. 외부 노출은 명시적으로 선택해야 합니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if model.snapshot.tunnels.isEmpty {
                    InspectorHint(
                        icon: "arrow.left.arrow.right",
                        text: AppText.string("Saved and active tunnels appear here.", korean: "저장된 터널과 활성 터널이 여기에 표시됩니다.")
                    )
                } else {
                    ForEach(model.snapshot.tunnels) { tunnel in
                        TunnelRow(
                            tunnel: tunnel,
                            onStart: { model.startTunnel(id: tunnel.id) },
                            onStop: { model.stopTunnel(id: tunnel.id) },
                            onRestart: { model.restartTunnel(id: tunnel.id) },
                            onProbe: { model.probeTunnelDestination(id: tunnel.id) },
                            onEdit: { model.editTunnel(tunnel) },
                            onDelete: { tunnelPendingDeletion = tunnel },
                            isEnabled: model.isServiceAvailable
                        )
                    }
                }
            }
            .padding(12)
        }
        .confirmationDialog(
            AppText.string("Delete this tunnel?", korean: "이 터널을 삭제할까요?"),
            isPresented: Binding(
                get: { tunnelPendingDeletion != nil },
                set: { if !$0 { tunnelPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: tunnelPendingDeletion
        ) { tunnel in
            Button(AppText.delete, role: .destructive) {
                model.deleteTunnel(id: tunnel.id)
                tunnelPendingDeletion = nil
            }
            Button(AppText.cancel, role: .cancel) { tunnelPendingDeletion = nil }
        }
    }
}

private struct TunnelRow: View {
    let tunnel: TunnelPresentation
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onProbe: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(tunnel.name.isEmpty ? directionTitle : tunnel.name, systemImage: tunnelIcon)
                    .font(.callout.weight(.medium))
                Spacer()
                TunnelPhaseLabel(phase: tunnel.phase)
            }
            Text(endpointDescription)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TunnelDestinationLabel(
                reachability: tunnel.destinationReachability,
                direction: tunnel.direction
            )
            HStack(spacing: 10) {
                if tunnel.isIndependent {
                    Label(AppText.string("Independent", korean: "독립 실행"), systemImage: "menubar.rectangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                controlButton
                probeButton
                Menu {
                    Button(AppText.edit, action: onEdit)
                    Button(AppText.string("Restart", korean: "다시 시작"), action: onRestart)
                    Divider()
                    Button(AppText.delete, role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(AppText.string("Tunnel actions", korean: "터널 작업"))
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var controlButton: some View {
        switch tunnel.phase {
        case .stopped, .failed:
            Button(AppText.string("Start", korean: "시작"), action: onStart)
                .buttonStyle(.borderless)
        case .listening, .starting, .stopping:
            Button(AppText.string("Stop", korean: "중지"), action: onStop)
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var probeButton: some View {
        if tunnel.destinationReachability != .notApplicable {
            Button(AppText.string("Check Destination", korean: "대상 확인"), action: onProbe)
                .buttonStyle(.borderless)
                .disabled(tunnel.phase != .listening || tunnel.destinationReachability == .probing)
                .accessibilityLabel(AppText.string("Check tunnel destination", korean: "터널 대상 확인"))
        }
    }

    private var tunnelIcon: String {
        switch tunnel.direction {
        case .local: "arrow.right"
        case .remote: "arrow.left"
        case .dynamic: "circle.dotted"
        case .remoteDynamic: "circle.dotted.circle"
        case .localSocket, .remoteSocket: "cable.connector"
        }
    }

    private var directionTitle: String {
        switch tunnel.direction {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "SOCKS"
        case .remoteDynamic: "Remote SOCKS"
        case .localSocket: "Local Socket"
        case .remoteSocket: "Remote Socket"
        }
    }

    private var endpointDescription: String {
        let listener = tunnel.listeningEndpoint ?? tunnel.bindAddress
        if let destination = tunnel.destination, !destination.isEmpty {
            return "\(listener) → \(destination)"
        }
        return listener
    }
}

private struct TunnelDestinationLabel: View {
    let reachability: TunnelDestinationReachability
    let direction: TunnelDirectionPresentation

    var body: some View {
        Label(title, systemImage: symbolName)
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(2)
            .accessibilityLabel(title)
    }

    private var title: String {
        switch reachability {
        case .notApplicable:
            AppText.string("No destination to check", korean: "확인할 대상 없음")
        case .notProbed:
            AppText.string("Destination not checked", korean: "대상 미확인")
        case .probing:
            AppText.string("Checking destination", korean: "대상 확인 중")
        case .reachable:
            reachabilitySuccessTitle
        case let .unreachable(message):
            reachabilityFailureTitle(message)
        }
    }

    private var reachabilitySuccessTitle: String {
        switch direction {
        case .local, .localSocket:
            AppText.string(
                "Destination reachable through listener",
                korean: "listener를 통한 대상 연결 가능"
            )
        case .remote, .remoteSocket:
            AppText.string(
                "Local destination reachable",
                korean: "로컬 대상 연결 가능"
            )
        case .dynamic, .remoteDynamic:
            AppText.string("Destination reachable", korean: "대상 연결 가능")
        }
    }

    private func reachabilityFailureTitle(_ message: String) -> String {
        switch direction {
        case .local, .localSocket:
            AppText.string(
                "Destination unavailable through listener: \(message)",
                korean: "listener를 통한 대상 연결 실패: \(message)"
            )
        case .remote, .remoteSocket:
            AppText.string(
                "Local destination unavailable: \(message)",
                korean: "로컬 대상 연결 실패: \(message)"
            )
        case .dynamic, .remoteDynamic:
            AppText.string(
                "Destination unavailable: \(message)",
                korean: "대상 연결 실패: \(message)"
            )
        }
    }

    private var symbolName: String {
        switch reachability {
        case .notApplicable: "minus.circle"
        case .notProbed: "questionmark.circle"
        case .probing: "arrow.triangle.2.circlepath"
        case .reachable: "checkmark.circle"
        case .unreachable: "xmark.octagon"
        }
    }

    private var color: Color {
        switch reachability {
        case .reachable: .green
        case .probing: .orange
        case .unreachable: .red
        case .notApplicable, .notProbed: .secondary
        }
    }
}

private struct TunnelPhaseLabel: View {
    let phase: TunnelPhasePresentation

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    private var title: String {
        switch phase {
        case .stopped: AppText.string("Stopped", korean: "중지됨")
        case .starting: AppText.string("Starting", korean: "시작 중")
        case .listening: AppText.string("Listening", korean: "수신 대기")
        case .failed: AppText.string("Failed", korean: "실패")
        case .stopping: AppText.string("Stopping", korean: "중지 중")
        }
    }

    private var color: Color {
        switch phase {
        case .listening: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

private struct ConnectionInspector: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var snippetPrompt: SnippetPresentation?
    @State private var snippetValues: [UUID: String] = [:]
    @State private var snippetEditorRequest: SnippetEditorRequest?

    private var selectedSession: TerminalSessionPresentation? { model.selectedSession }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sessionSection
                Divider()
                broadcastSection
                Divider()
                snippetsSection
            }
            .padding(12)
        }
        .sheet(item: $snippetPrompt) { snippet in
            SnippetVariableEntrySheet(
                snippet: snippet,
                values: $snippetValues,
                onRun: {
                    model.runSnippet(id: snippet.id, on: snippetTargets, values: snippetValues)
                    snippetPrompt = nil
                    snippetValues.removeAll(keepingCapacity: false)
                },
                onCancel: {
                    snippetPrompt = nil
                    snippetValues.removeAll(keepingCapacity: false)
                }
            )
        }
        .sheet(item: $snippetEditorRequest) { request in
            SnippetEditorSheet(
                initialTitle: request.title,
                initialCommands: request.commandsText,
                isEditing: request.existingSnippetID != nil,
                onSave: { title, commands in
                    if let id = request.existingSnippetID {
                        model.updateSnippet(id: id, title: title, commandsText: commands)
                    } else {
                        model.saveSnippet(title: title, commandsText: commands)
                    }
                    snippetEditorRequest = nil
                },
                onCancel: { snippetEditorRequest = nil }
            )
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AppText.connection, systemImage: "network")
                .font(.headline)
            if let session = selectedSession {
                LabeledContent(AppText.string("Session", korean: "세션")) {
                    Text(session.title).lineLimit(1)
                }
                LabeledContent(AppText.string("Status", korean: "상태")) {
                    Text(session.accessibilityState)
                        .foregroundStyle(statusColor(session.state))
                }
                if let process = session.activeProcessDescription, !process.isEmpty {
                    LabeledContent(AppText.string("Process", korean: "프로세스")) {
                        Text(process).lineLimit(1)
                    }
                }
                if let path = session.currentDirectory, !path.isEmpty {
                    LabeledContent(AppText.string("Remote Path", korean: "원격 경로")) {
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                }
                if session.state.isInputReady {
                    Button(AppText.disconnect) {
                        model.disconnect(sessionID: session.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isServiceAvailable)
                }
            } else {
                InspectorHint(
                    icon: "network.slash",
                    text: AppText.string("Select an active session to see connection details.", korean: "연결 정보를 보려면 활성 세션을 선택하세요.")
                )
            }
        }
    }

    private var broadcastSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AppText.string("Broadcast Input", korean: "동시 입력"), systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            Text(AppText.string(
                "Choose at least two sessions. Input typed in any checked terminal is mirrored only to the other checked, connected sessions. It is off by default.",
                korean: "세션을 두 개 이상 선택하세요. 선택한 터미널에서 입력한 내용은 선택한 다른 연결 세션에만 복제됩니다. 기본값은 꺼짐입니다."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            let eligibleSessions = model.snapshot.sessions.filter { $0.state.isInputReady && !$0.isReadOnly }
            if eligibleSessions.isEmpty {
                InspectorHint(
                    icon: "dot.radiowaves.left.and.right",
                    text: AppText.string("No connected sessions can receive broadcast input.", korean: "동시 입력을 받을 수 있는 연결된 세션이 없습니다.")
                )
            } else {
                ForEach(eligibleSessions) { session in
                    Toggle(isOn: broadcastBinding(for: session.id)) {
                        Text(session.title).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!model.isServiceAvailable)
                    .accessibilityLabel(AppText.string("Broadcast to \(session.title)", korean: "\(session.title)에 동시 입력"))
                }
                let activeTargetCount = Set(eligibleSessions.map(\.id))
                    .intersection(model.snapshot.broadcastTargetSessionIDs)
                    .count
                if activeTargetCount >= 2 {
                    HStack {
                        Label(
                            AppText.string(
                                "Broadcasting across \(activeTargetCount) sessions",
                                korean: "\(activeTargetCount)개 세션에 동시 입력 중"
                            ),
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        Spacer()
                        Button(AppText.string("Turn Off", korean: "끄기")) {
                            model.setBroadcastTargets([])
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.isServiceAvailable)
                        .accessibilityLabel(AppText.string("Turn off broadcast input", korean: "동시 입력 끄기"))
                    }
                } else if activeTargetCount == 1 {
                    Text(AppText.string(
                        "Select one more session before broadcast becomes active.",
                        korean: "세션을 하나 더 선택하면 동시 입력이 활성화됩니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppText.string("Command Snippets", korean: "명령 스니펫"), systemImage: "text.badge.plus")
                    .font(.headline)
                Spacer()
                Button {
                    snippetEditorRequest = SnippetEditorRequest()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(AppText.string("New command snippet", korean: "새 명령 스니펫"))
                .disabled(!model.isServiceAvailable)
            }
            if model.snapshot.snippets.isEmpty {
                InspectorHint(
                    icon: "text.badge.plus",
                    text: AppText.string(
                        "Create a snippet to save an explicit command sequence.",
                        korean: "명시적으로 실행할 명령 순서를 저장하려면 스니펫을 만드세요."
                    )
                )
            }
            ForEach(model.snapshot.snippets) { snippet in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snippet.title)
                            .font(.callout.weight(.medium))
                        Text(snippet.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(AppText.string("Run", korean: "실행")) {
                        if snippet.requiresInput {
                            snippetValues = Dictionary(uniqueKeysWithValues: snippet.variables.map { ($0.id, "") })
                            snippetPrompt = snippet
                        } else {
                            model.runSnippet(id: snippet.id, on: snippetTargets)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isServiceAvailable || model.selectedSession == nil)
                    Menu {
                        Button(AppText.string("Edit", korean: "수정")) {
                            snippetEditorRequest = SnippetEditorRequest(
                                existingSnippetID: snippet.id,
                                title: snippet.title,
                                commandsText: snippet.commandsText
                            )
                        }
                        Button(AppText.delete, role: .destructive) {
                            model.deleteSnippet(id: snippet.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(AppText.string("Snippet actions", korean: "스니펫 작업"))
                    .disabled(!model.isServiceAvailable)
                }
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func broadcastBinding(for sessionID: UUID) -> Binding<Bool> {
        Binding(
            get: { model.snapshot.broadcastTargetSessionIDs.contains(sessionID) },
            set: { isSelected in
                var targets = model.snapshot.broadcastTargetSessionIDs
                if isSelected {
                    targets.insert(sessionID)
                } else {
                    targets.remove(sessionID)
                }
                model.setBroadcastTargets(targets)
            }
        )
    }

    private var snippetTargets: Set<UUID> {
        model.snapshot.broadcastTargetSessionIDs.isEmpty
            ? Set(model.selectedSession.map { [$0.id] } ?? [])
            : model.snapshot.broadcastTargetSessionIDs
    }

    private func statusColor(_ state: SessionPresentationState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .failed: .red
        case .idle, .disconnected: .secondary
        }
    }
}

private struct SnippetEditorRequest: Identifiable {
    let id = UUID()
    var existingSnippetID: UUID?
    var title: String
    var commandsText: String

    init(existingSnippetID: UUID? = nil, title: String = "", commandsText: String = "") {
        self.existingSnippetID = existingSnippetID
        self.title = title
        self.commandsText = commandsText
    }
}

private struct SnippetEditorSheet: View {
    @State private var title: String
    @State private var commands: String
    let isEditing: Bool
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    init(
        initialTitle: String,
        initialCommands: String,
        isEditing: Bool,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _title = State(initialValue: initialTitle)
        _commands = State(initialValue: initialCommands)
        self.isEditing = isEditing
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing
                ? AppText.string("Edit Command Snippet", korean: "명령 스니펫 수정")
                : AppText.string("New Command Snippet", korean: "새 명령 스니펫")
            )
                .font(.title3.weight(.semibold))
            TextField(AppText.string("Title", korean: "제목"), text: $title)
                .textFieldStyle(.roundedBorder)
            Text(AppText.string(
                "One command per line. Use {{name}} to ask for a value at run time.",
                korean: "한 줄에 하나의 명령을 입력하세요. {{name}}을 사용하면 실행할 때 값을 입력받습니다."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            TextEditor(text: $commands)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.quaternary)
                }
            HStack {
                Spacer()
                Button(AppText.cancel, action: onCancel)
                Button(AppText.save) { onSave(title, commands) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct SnippetVariableEntrySheet: View {
    let snippet: SnippetPresentation
    @Binding var values: [UUID: String]
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(snippet.title).font(.title3.weight(.semibold))
            Text(AppText.string(
                "Enter values for this command. Values are used once and are not saved.",
                korean: "명령에 사용할 값을 입력하세요. 값은 한 번만 사용하며 저장하지 않습니다."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            ForEach(snippet.variables) { variable in
                VStack(alignment: .leading, spacing: 5) {
                    Text(variable.prompt.isEmpty ? variable.name : variable.prompt)
                        .font(.caption.weight(.medium))
                    if variable.isSecret {
                        SecureField(variable.name, text: binding(for: variable.id))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(variable.name, text: binding(for: variable.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Spacer()
                Button(AppText.cancel, action: onCancel)
                Button(AppText.string("Run", korean: "실행"), action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.variables.contains { (values[$0.id] ?? "").isEmpty })
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { values[id] ?? "" },
            set: { values[id] = $0 }
        )
    }
}

struct InspectorHint: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RemoteFolderNameSheet: View {
    let title: String
    @Binding var name: String
    let confirmTitle: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
            TextField(AppText.string("Name", korean: "이름"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppText.string("Name", korean: "이름"))
            HStack {
                Spacer()
                Button(AppText.cancel, role: .cancel) { dismiss() }
                Button(confirmTitle) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
