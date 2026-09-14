import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceRootView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var authenticationResponse = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AppSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 225, ideal: 270, max: 360)
        } detail: {
            HStack(spacing: 0) {
                WorkspaceCenterView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.isInspectorVisible {
                    Divider()
                    InspectorView(model: model)
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.isInspectorVisible)
            .overlay(alignment: .top) {
                if let unavailableReason = model.unavailableReason {
                    ServiceUnavailableBanner(message: unavailableReason, onRetry: model.refresh)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbarContent }
        .sheet(item: $model.profileEditorRequest) { request in
            ProfileEditorView(
                request: request,
                folders: model.snapshot.folders,
                profiles: model.snapshot.profiles,
                isServiceAvailable: model.isServiceAvailable,
                onSave: model.saveProfile
            )
        }
        .sheet(item: $model.tunnelEditorRequest) { request in
            TunnelEditorView(
                request: request,
                isServiceAvailable: model.isServiceAvailable,
                onSave: model.saveTunnel
            )
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(model: model)
                .frame(minWidth: 560, minHeight: 480)
        }
        .sheet(item: authenticationChallengeBinding) { challenge in
            AuthenticationPromptView(
                challenge: challenge,
                response: $authenticationResponse,
                onSubmit: {
                    model.respond(to: challenge, response: authenticationResponse)
                    authenticationResponse.removeAll(keepingCapacity: false)
                },
                onCancel: {
                    model.respond(to: challenge, response: nil)
                    authenticationResponse.removeAll(keepingCapacity: false)
                }
            )
            .onDisappear {
                authenticationResponse.removeAll(keepingCapacity: false)
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(AppText.string("OK", korean: "확인")))
            )
        }
        .preferredColorScheme(colorScheme)
        .onAppear(perform: model.refresh)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.beginNewProfile()
            } label: {
                Label(AppText.newConnection, systemImage: "plus")
            }
            .accessibilityLabel(AppText.newConnection)
            .help(AppText.newConnection)
            .disabled(!model.isServiceAvailable)

            Menu {
                Button(AppText.string("Import SSH Config…", korean: "SSH 설정 가져오기…")) {
                    chooseSSHConfigForImport()
                }
                .disabled(!model.isServiceAvailable)

                Button(AppText.string("Export Profiles…", korean: "프로필 내보내기…")) {
                    chooseProfileExport()
                }
                .disabled(!model.isServiceAvailable || model.snapshot.profiles.isEmpty)
            } label: {
                Label(AppText.string("Profile Actions", korean: "프로필 작업"), systemImage: "ellipsis.circle")
            }
            .accessibilityLabel(AppText.string("Profile Actions", korean: "프로필 작업"))
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.startLocalTerminal()
            } label: {
                Label(AppText.localTerminal, systemImage: "terminal")
            }
            .accessibilityLabel(AppText.localTerminal)
            .help(AppText.localTerminal)
            .disabled(!model.isServiceAvailable)

            Menu {
                ForEach(WorkspaceLayoutPresentation.allCases) { layout in
                    Button {
                        model.setLayout(layout)
                    } label: {
                        Label(layoutTitle(layout), systemImage: layout.symbolName)
                    }
                }
            } label: {
                Label(AppText.string("Split Workspace", korean: "작업 공간 분할"), systemImage: model.snapshot.layout.symbolName)
            }
            .accessibilityLabel(AppText.string("Change workspace layout", korean: "작업 공간 레이아웃 변경"))
            .disabled(!model.isServiceAvailable)

            Button {
                model.inspectorSection = .tunnels
                model.isInspectorVisible = true
                model.beginNewTunnel(for: model.selectedSession?.id)
            } label: {
                Label(AppText.string("New Tunnel", korean: "새 터널"), systemImage: "arrow.left.arrow.right")
            }
            .accessibilityLabel(AppText.string("New tunnel", korean: "새 터널"))
            .disabled(!model.isServiceAvailable)

            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Label(
                    model.isInspectorVisible
                        ? AppText.string("Hide Inspector", korean: "검사기 숨기기")
                        : AppText.string("Show Inspector", korean: "검사기 표시"),
                    systemImage: "sidebar.right"
                )
            }
            .accessibilityLabel(
                model.isInspectorVisible
                    ? AppText.string("Hide inspector", korean: "검사기 숨기기")
                    : AppText.string("Show inspector", korean: "검사기 표시")
            )

            Button {
                model.isSettingsPresented = true
            } label: {
                Label(AppText.settings, systemImage: "gearshape")
            }
            .accessibilityLabel(AppText.settings)
            .help(AppText.settings)
        }
    }

    private var authenticationChallengeBinding: Binding<AuthenticationChallengePresentation?> {
        Binding(
            get: { model.snapshot.authenticationChallenge },
            set: { _ in }
        )
    }

    private var colorScheme: ColorScheme? {
        switch model.snapshot.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private func layoutTitle(_ layout: WorkspaceLayoutPresentation) -> String {
        switch layout {
        case .single:
            AppText.string("Single Pane", korean: "단일 패널")
        case .horizontalSplit:
            AppText.string("Split Horizontally", korean: "가로 분할")
        case .verticalSplit:
            AppText.string("Split Vertically", korean: "세로 분할")
        }
    }

    private func chooseSSHConfigForImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = AppText.string(
            "Choose an OpenSSH config file. Import never executes Match exec or ProxyCommand.",
            korean: "OpenSSH 설정 파일을 선택하세요. 가져오기 중에는 Match exec 및 ProxyCommand를 실행하지 않습니다."
        )
        if panel.runModal() == .OK, let url = panel.url {
            model.importSSHConfig(from: url)
        }
    }

    private func chooseProfileExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "osxterm-profiles.json"
        panel.message = AppText.string(
            "Export excludes passwords, private key content and passphrases.",
            korean: "내보내기에는 비밀번호, 개인 키 내용, 암호 문구가 포함되지 않습니다."
        )
        if panel.runModal() == .OK, let url = panel.url {
            model.exportProfiles(ids: model.snapshot.profiles.map(\.id), to: url)
        }
    }
}

private struct ServiceUnavailableBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
            Spacer(minLength: 8)
            Button(AppText.string("Retry", korean: "다시 시도"), action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.quaternary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppText.string("Service unavailable. \(message)", korean: "서비스를 사용할 수 없습니다. \(message)"))
    }
}

private struct AuthenticationPromptView: View {
    let challenge: AuthenticationChallengePresentation
    @Binding var response: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbolName)
                .font(.title3.weight(.semibold))
            Text(challenge.prompt)
                .fixedSize(horizontal: false, vertical: true)
            if let attemptDescription = challenge.attemptDescription {
                Text(attemptDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(24)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch challenge.kind {
        case .credential:
            credentialContent
        case let .hostKeyNew(fingerprint):
            hostKeyContent(
                fingerprint: fingerprint,
                isChanged: false,
                trustMarker: "trust-new-host-key"
            )
        case let .hostKeyChanged(fingerprint):
            hostKeyContent(
                fingerprint: fingerprint,
                isChanged: true,
                trustMarker: "trust-changed-host-key"
            )
        }
    }

    private var credentialContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if challenge.isSecure {
                SecureField(AppText.string("Response", korean: "응답"), text: $response)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(AppText.string("Secure authentication response", korean: "보안 인증 응답"))
            } else {
                TextField(AppText.string("Response", korean: "응답"), text: $response)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(AppText.string("Authentication response", korean: "인증 응답"))
            }
            HStack {
                Spacer()
                Button(AppText.cancel, role: .cancel, action: onCancel)
                Button(AppText.string("Continue", korean: "계속"), action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(response.isEmpty)
            }
        }
    }

    private func hostKeyContent(
        fingerprint: String,
        isChanged: Bool,
        trustMarker: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isChanged
                ? AppText.string(
                    "The saved host key does not match the server. Verify this fingerprint through an independent channel before replacing it.",
                    korean: "저장된 호스트 키가 서버와 일치하지 않습니다. 교체하기 전에 별도 경로로 이 fingerprint를 확인하세요."
                )
                : AppText.string(
                    "This server has not been trusted yet. Verify its fingerprint before continuing.",
                    korean: "이 서버는 아직 신뢰되지 않았습니다. 계속하기 전에 fingerprint를 확인하세요."
                )
            )
            .foregroundStyle(isChanged ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(fingerprint)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(AppText.string("Host key fingerprint \(fingerprint)", korean: "호스트 키 fingerprint \(fingerprint)"))
            HStack {
                Spacer()
                Button(AppText.string("Reject", korean: "거부"), role: .cancel, action: onCancel)
                Button(
                    isChanged
                        ? AppText.string("Trust New Key", korean: "새 키 신뢰")
                        : AppText.string("Trust and Connect", korean: "신뢰하고 연결")
                ) {
                    response = trustMarker
                    onSubmit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var title: String {
        switch challenge.kind {
        case .credential:
            AppText.string("Authentication Required", korean: "인증이 필요합니다")
        case .hostKeyNew:
            AppText.string("Verify Host Key", korean: "호스트 키 확인")
        case .hostKeyChanged:
            AppText.string("Host Key Changed", korean: "호스트 키가 변경되었습니다")
        }
    }

    private var symbolName: String {
        switch challenge.kind {
        case .credential: "lock.shield"
        case .hostKeyNew: "checkmark.shield"
        case .hostKeyChanged: "exclamationmark.shield"
        }
    }
}
