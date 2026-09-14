import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceCenterView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var renameTarget: TerminalSessionPresentation?
    @State private var renamedTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            if !model.snapshot.sessions.isEmpty {
                SessionTabStrip(
                    sessions: model.snapshot.sessions,
                    selectedSessionID: model.snapshot.selectedSessionID,
                    onSelect: { model.selectSession(id: $0) },
                    onClose: { model.closeSession(id: $0) },
                    onRename: { session in
                        renamedTitle = session.title
                        renameTarget = session
                    },
                    onDuplicate: { model.duplicateSession(id: $0) },
                    onMove: { id, index in model.moveSession(id: id, toIndex: index) },
                    isEnabled: model.isServiceAvailable
                )
                Divider()
            }

            if model.snapshot.sessions.isEmpty {
                EmptyWorkspaceView(model: model)
            } else {
                SessionWorkspace(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel(AppText.string("Terminal workspace", korean: "터미널 작업 공간"))
        .sheet(item: $renameTarget) { session in
            TabRenameSheet(
                title: $renamedTitle,
                onConfirm: {
                    model.renameSession(id: session.id, title: renamedTitle)
                    renameTarget = nil
                    renamedTitle = ""
                },
                onCancel: {
                    renameTarget = nil
                    renamedTitle = ""
                }
            )
        }
    }
}

private struct EmptyWorkspaceView: View {
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        ContentUnavailableView {
            Label(AppText.string("Open a terminal", korean: "터미널 열기"), systemImage: "terminal")
        } description: {
            Text(AppText.string(
                "Connect to a saved server or start a local shell.",
                korean: "저장한 서버에 연결하거나 로컬 셸을 시작하세요."
            ))
        } actions: {
            HStack(spacing: 10) {
                Button(AppText.newConnection) {
                    model.beginNewProfile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isServiceAvailable)

                Button(AppText.localTerminal) {
                    model.startLocalTerminal()
                }
                .buttonStyle(.bordered)
                .disabled(!model.isServiceAvailable)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SessionTabStrip: View {
    let sessions: [TerminalSessionPresentation]
    let selectedSessionID: UUID?
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onRename: (TerminalSessionPresentation) -> Void
    let onDuplicate: (UUID) -> Void
    let onMove: (UUID, Int) -> Void
    let isEnabled: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    HStack(spacing: 5) {
                        Button {
                            onSelect(session.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: session.state.symbolName)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(for: session.state))
                                    .accessibilityHidden(true)
                                Text(session.title)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(session.title), \(session.accessibilityState)")

                        Button {
                            onClose(session.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(AppText.string("Close \(session.title)", korean: "\(session.title) 닫기"))
                        .help(AppText.disconnect)
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 5)
                    .background(
                        selectedSessionID == session.id ? Color.accentColor.opacity(0.16) : .clear,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(selectedSessionID == session.id ? Color.accentColor.opacity(0.45) : .clear)
                    }
                    .contextMenu {
                        Button(AppText.string("Rename", korean: "이름 바꾸기")) {
                            onRename(session)
                        }
                        Button(AppText.string("Duplicate", korean: "복제")) {
                            onDuplicate(session.id)
                        }
                        Divider()
                        Button(AppText.string("Move Left", korean: "왼쪽으로 이동")) {
                            onMove(session.id, index - 1)
                        }
                        .disabled(index == 0)
                        Button(AppText.string("Move Right", korean: "오른쪽으로 이동")) {
                            onMove(session.id, index + 1)
                        }
                        .disabled(index == sessions.count - 1)
                        Divider()
                        Button(AppText.string("Close Tab", korean: "탭 닫기"), role: .destructive) {
                            onClose(session.id)
                        }
                    }
                    .disabled(!isEnabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .accessibilityLabel(AppText.string("Open terminal sessions", korean: "열린 터미널 세션"))
    }

    private func statusColor(for state: SessionPresentationState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .failed: .red
        case .idle, .disconnected: .secondary
        }
    }
}

private struct TabRenameSheet: View {
    @Binding var title: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppText.string("Rename Tab", korean: "탭 이름 바꾸기"))
                .font(.title3.weight(.semibold))
            TextField(AppText.string("Tab name", korean: "탭 이름"), text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppText.string("Tab name", korean: "탭 이름"))
            HStack {
                Spacer()
                Button(AppText.cancel, action: onCancel)
                Button(AppText.string("Rename", korean: "이름 바꾸기"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}

private struct SessionWorkspace: View {
    @ObservedObject var model: AppWorkspaceModel

    private var paneSessions: [TerminalSessionPresentation] {
        let ids = model.snapshot.paneSessionIDs.isEmpty
            ? model.snapshot.selectedSessionID.map { [$0] } ?? []
            : model.snapshot.paneSessionIDs
        let byID = Dictionary(uniqueKeysWithValues: model.snapshot.sessions.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    var body: some View {
        Group {
            switch model.snapshot.layout {
            case .single:
                singlePane
            case .horizontalSplit:
                HStack(spacing: 0) {
                    pane(at: 0)
                    Divider()
                    pane(at: 1)
                }
            case .verticalSplit:
                VStack(spacing: 0) {
                    pane(at: 0)
                    Divider()
                    pane(at: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var singlePane: some View {
        if let session = paneSessions.first ?? model.selectedSession {
            TerminalPaneView(session: session, model: model)
        } else {
            InactivePaneView()
        }
    }

    @ViewBuilder
    private func pane(at index: Int) -> some View {
        if paneSessions.indices.contains(index) {
            TerminalPaneView(session: paneSessions[index], model: model)
        } else if index == 0, let session = model.selectedSession {
            TerminalPaneView(session: session, model: model)
        } else {
            InactivePaneView()
        }
    }
}

private struct InactivePaneView: View {
    var body: some View {
        ContentUnavailableView(
            AppText.string("No session in this pane", korean: "이 패널에 세션이 없습니다"),
            systemImage: "rectangle.dashed",
            description: Text(AppText.string(
                "Choose a session from the tab bar or change the workspace layout.",
                korean: "탭 막대에서 세션을 선택하거나 작업 공간 레이아웃을 바꾸세요."
            ))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalPaneView: View {
    let session: TerminalSessionPresentation
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            terminalHeader
            Divider()
            ZStack {
                AppKitTerminalSurface(
                    sessionID: session.id,
                    launch: session.launch,
                    pendingInput: session.pendingInput,
                    fontName: model.snapshot.settings.terminalFontName,
                    fontSize: model.snapshot.settings.terminalFontSize,
                    lineSpacing: model.snapshot.settings.terminalLineSpacing,
                    themeName: model.snapshot.settings.terminalThemeName,
                    isInputEnabled: session.state.isInputReady && !session.isReadOnly && model.isServiceAvailable,
                    allowsRemoteClipboard: model.snapshot.settings.allowRemoteClipboard,
                    accessibilityLabel: AppText.string(
                        "\(session.title) terminal. \(session.accessibilityState)",
                        korean: "\(session.title) 터미널. \(session.accessibilityState)"
                    ),
                    onInput: { data in
                        model.terminalInputDidSend(data, from: session.id)
                    },
                    onResize: { columns, rows in
                        model.terminalDidResize(sessionID: session.id, columns: columns, rows: rows)
                    },
                    onProcessStarted: { launchID in
                        model.terminalProcessDidStart(sessionID: session.id, launchID: launchID)
                    },
                    onProcessTerminated: { launchID, exitCode in
                        model.terminalProcessDidTerminate(
                            sessionID: session.id,
                            launchID: launchID,
                            exitCode: exitCode
                        )
                    },
                    onProcessOutput: { launchID, data in
                        model.terminalProcessDidOutput(
                            sessionID: session.id,
                            launchID: launchID,
                            data: data
                        )
                    }
                )
                .id(session.id)
                .padding(10)

                if !session.state.isInputReady || session.isReadOnly {
                    TerminalStatusOverlay(session: session)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var terminalHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isLocal ? "laptopcomputer" : "server.rack")
                .foregroundStyle(session.isLocal ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            SessionStateLabel(state: session.state)
            if session.isSessionLoggingEnabled {
                Image(systemName: "record.circle")
                    .foregroundStyle(.secondary)
                    .help(AppText.string("Session logging is enabled", korean: "세션 로그 기록이 켜져 있습니다"))
                    .accessibilityLabel(AppText.string("Session logging is enabled", korean: "세션 로그 기록이 켜져 있습니다"))
            }
            Button {
                chooseSessionLogExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help(AppText.string("Export Session Log", korean: "세션 로그 내보내기"))
            .accessibilityLabel(AppText.string("Export log for \(session.title)", korean: "\(session.title) 로그 내보내기"))
            .disabled(!session.hasSessionLog || !model.isServiceAvailable)
            if session.state.isInputReady {
                Button {
                    model.disconnect(sessionID: session.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(AppText.disconnect)
                .accessibilityLabel(AppText.string("Disconnect \(session.title)", korean: "\(session.title) 연결 해제"))
                .disabled(!model.isServiceAvailable)
            } else if let profileID = session.profileID, !session.isLocal {
                Button {
                    model.connect(profileID: profileID)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(AppText.reconnect)
                .accessibilityLabel(AppText.string("Reconnect \(session.title)", korean: "\(session.title) 재연결"))
                .disabled(!model.isServiceAvailable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var headerSubtitle: String {
        if let directory = session.currentDirectory, !directory.isEmpty {
            return directory
        }
        if let process = session.activeProcessDescription, !process.isEmpty {
            return process
        }
        return session.accessibilityState
    }

    private func chooseSessionLogExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.nameFieldStringValue = "osxterm-session-\(session.id.uuidString.prefix(8).lowercased()).log"
        panel.message = AppText.string(
            "Choose a location for this opt-in terminal log. It can include sensitive terminal input and output.",
            korean: "사용자가 기록한 터미널 로그의 저장 위치를 선택하세요. 민감한 터미널 입력과 출력이 포함될 수 있습니다."
        )
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSessionLog(sessionID: session.id, to: url)
        }
    }
}

private struct TerminalStatusOverlay: View {
    let session: TerminalSessionPresentation

    var body: some View {
        VStack(spacing: 8) {
            if case .connecting = session.state {
                ProgressView()
            } else if case .authenticating = session.state {
                ProgressView()
            } else if case .reconnecting = session.state {
                ProgressView()
            } else {
                Image(systemName: session.state.symbolName)
                    .font(.title2)
            }
            Text(session.accessibilityState)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
            if session.isReadOnly {
                Text(AppText.string(
                    "Input is disabled for this session.",
                    korean: "이 세션에서는 입력이 비활성화되어 있습니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionStateLabel: View {
    let state: SessionPresentationState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbolName)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(color)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch state {
        case .idle:
            AppText.string("Idle", korean: "대기")
        case .connecting:
            AppText.string("Connecting", korean: "연결 중")
        case .authenticating:
            AppText.string("Authenticating", korean: "인증 중")
        case .connected:
            AppText.string("Connected", korean: "연결됨")
        case .reconnecting:
            AppText.string("Reconnecting", korean: "재연결 중")
        case .disconnected:
            AppText.string("Disconnected", korean: "연결 끊김")
        case .failed:
            AppText.string("Failed", korean: "실패")
        }
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .failed: .red
        case .idle, .disconnected: .secondary
        }
    }
}
