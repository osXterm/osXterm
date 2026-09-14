import AppKit
import SwiftUI

struct ProfileEditorView: View {
    let request: ProfileEditorRequest
    let folders: [FolderPresentation]
    let profiles: [ProfilePresentation]
    let isServiceAvailable: Bool
    let onSave: (ProfileEditorSubmission) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProfileDraftPresentation
    @State private var profilePassword = ""
    @State private var keyPassphrase = ""
    @State private var proxyPassword = ""
    @State private var tagText = ""
    @State private var isAdvancedExpanded = false
    @State private var isForwardingExpanded = false

    init(
        request: ProfileEditorRequest,
        folders: [FolderPresentation],
        profiles: [ProfilePresentation],
        isServiceAvailable: Bool,
        onSave: @escaping (ProfileEditorSubmission) -> Void
    ) {
        self.request = request
        self.folders = folders
        self.profiles = profiles
        self.isServiceAvailable = isServiceAvailable
        self.onSave = onSave
        _draft = State(initialValue: request.draft)
        _tagText = State(initialValue: request.draft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    basicSection
                    authenticationSection
                    routeSection
                    advancedSection
                    forwardingSection
                }
                .padding(24)
            }
            Divider()
            editorFooter
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 620, idealHeight: 780)
        .accessibilityElement(children: .contain)
    }

    private var editorHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.mode == .create ? AppText.newConnection : AppText.string("Edit Connection", korean: "연결 편집"))
                    .font(.title2.weight(.semibold))
                Text(AppText.string(
                    "Credentials are stored by the core service in Keychain, not in this form or profile export.",
                    korean: "자격 증명은 이 양식이나 프로필 내보내기가 아닌 코어 서비스의 Keychain에 저장됩니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if draft.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(AppText.string("Favorite", korean: "즐겨찾기"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var basicSection: some View {
        EditorSection(title: AppText.string("Connection", korean: "연결"), symbol: "server.rack") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    editorLabel(AppText.string("Name", korean: "이름"))
                    TextField(AppText.string("Production API", korean: "운영 API"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(AppText.string("Connection name", korean: "연결 이름"))
                }
                GridRow {
                    editorLabel(AppText.string("Host", korean: "호스트"))
                    TextField(AppText.string("host.example.com or IPv6 address", korean: "host.example.com 또는 IPv6 주소"), text: $draft.host)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(AppText.string("Host", korean: "호스트"))
                }
                GridRow {
                    editorLabel(AppText.string("Port", korean: "포트"))
                    TextField("22", text: $draft.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120, alignment: .leading)
                        .accessibilityLabel(AppText.string("SSH port", korean: "SSH 포트"))
                }
                GridRow {
                    editorLabel(AppText.string("Username", korean: "사용자 이름"))
                    TextField(AppText.string("deploy", korean: "deploy"), text: $draft.username)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(AppText.string("Username", korean: "사용자 이름"))
                }
                GridRow {
                    editorLabel(AppText.string("Folder", korean: "폴더"))
                    Picker(AppText.string("Folder", korean: "폴더"), selection: $draft.folderID) {
                        Text(AppText.string("No Folder", korean: "폴더 없음")).tag(UUID?.none)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                }
                GridRow {
                    editorLabel(AppText.string("Tags", korean: "태그"))
                    TextField(AppText.string("Comma separated", korean: "쉼표로 구분"), text: $tagText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(AppText.string("Tags", korean: "태그"))
                }
                GridRow {
                    editorLabel(AppText.favorites)
                    Toggle(AppText.string("Add to Favorites", korean: "즐겨찾기에 추가"), isOn: $draft.isFavorite)
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var authenticationSection: some View {
        EditorSection(title: AppText.string("Authentication", korean: "인증"), symbol: "key") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    editorLabel(AppText.string("Method", korean: "방식"))
                    Picker(AppText.string("Authentication method", korean: "인증 방식"), selection: $draft.authenticationMethod) {
                        ForEach(AuthenticationMethodPresentation.allCases) { method in
                            Text(authenticationTitle(method)).tag(method)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }

                switch draft.authenticationMethod {
                case .sshAgent:
                    GridRow {
                        editorLabel(AppText.string("Agent Socket", korean: "에이전트 소켓"))
                        HStack {
                            TextField(AppText.string("Default SSH_AUTH_SOCK", korean: "기본 SSH_AUTH_SOCK"), text: $draft.agentSocketPath)
                                .textFieldStyle(.roundedBorder)
                            Button(AppText.string("Choose…", korean: "선택…")) {
                                chooseFile { draft.agentSocketPath = $0.path }
                            }
                        }
                    }
                case .privateKey, .certificate:
                    GridRow {
                        editorLabel(AppText.string("Private Key", korean: "개인 키"))
                        HStack {
                            TextField(AppText.string("Path to private key", korean: "개인 키 경로"), text: $draft.identityFilePath)
                                .textFieldStyle(.roundedBorder)
                            Button(AppText.string("Choose…", korean: "선택…")) {
                                chooseFile { draft.identityFilePath = $0.path }
                            }
                        }
                    }
                    if draft.authenticationMethod == .certificate {
                        GridRow {
                            editorLabel(AppText.string("Certificate", korean: "인증서"))
                            HStack {
                                TextField(AppText.string("Path to SSH certificate", korean: "SSH 인증서 경로"), text: $draft.certificateFilePath)
                                    .textFieldStyle(.roundedBorder)
                                Button(AppText.string("Choose…", korean: "선택…")) {
                                    chooseFile { draft.certificateFilePath = $0.path }
                                }
                            }
                        }
                    }
                    GridRow {
                        editorLabel(AppText.string("Key Passphrase", korean: "키 암호 문구"))
                        SecureField(AppText.string("Optional, stored in Keychain", korean: "선택 사항, Keychain에 저장"), text: $keyPassphrase)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(AppText.string("Private key passphrase", korean: "개인 키 암호 문구"))
                    }
                case .password:
                    GridRow {
                        editorLabel(AppText.string("Password", korean: "비밀번호"))
                        SecureField(AppText.string("Stored in Keychain", korean: "Keychain에 저장"), text: $profilePassword)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(AppText.string("Password", korean: "비밀번호"))
                    }
                case .keyboardInteractive:
                    GridRow {
                        editorLabel(AppText.string("Interactive Prompts", korean: "대화형 질문"))
                        Text(AppText.string(
                            "Prompts are shown at connection time and are never saved in the profile export.",
                            korean: "연결 시 질문을 표시하며 프로필 내보내기에는 저장하지 않습니다."
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var routeSection: some View {
        EditorSection(title: AppText.string("Route", korean: "경로"), symbol: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppText.string(
                    "Jump hosts are used in the displayed order. A profile cannot reference itself or form a route cycle.",
                    korean: "Jump host는 표시된 순서로 사용됩니다. 프로필 자신이나 순환 경로는 참조할 수 없습니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if availableJumpProfiles.isEmpty {
                    InspectorHint(
                        icon: "arrow.triangle.branch",
                        text: AppText.string("Save another profile first to use it as a jump host.", korean: "Jump host로 사용할 다른 프로필을 먼저 저장하세요.")
                    )
                } else {
                    ForEach(availableJumpProfiles) { profile in
                        Toggle(isOn: jumpBinding(for: profile.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name)
                                Text(profile.endpoint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Divider()
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        editorLabel(AppText.string("Proxy", korean: "프록시"))
                        Picker(AppText.string("Proxy", korean: "프록시"), selection: $draft.proxyKind) {
                            Text(AppText.string("None", korean: "없음")).tag(ProxyKindPresentation.none)
                            Text("HTTP CONNECT").tag(ProxyKindPresentation.httpConnect)
                            Text("SOCKS5").tag(ProxyKindPresentation.socks5)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    if draft.proxyKind != .none {
                        GridRow {
                            editorLabel(AppText.string("Proxy Host", korean: "프록시 호스트"))
                            TextField(AppText.string("proxy.example.com", korean: "proxy.example.com"), text: $draft.proxyHost)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            editorLabel(AppText.string("Proxy Port", korean: "프록시 포트"))
                            TextField("1080", text: $draft.proxyPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 120, alignment: .leading)
                        }
                        GridRow {
                            editorLabel(AppText.string("Proxy Username", korean: "프록시 사용자 이름"))
                            TextField(AppText.string("Optional", korean: "선택 사항"), text: $draft.proxyUsername)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            editorLabel(AppText.string("Proxy Password", korean: "프록시 비밀번호"))
                            SecureField(AppText.string("Optional, stored in Keychain", korean: "선택 사항, Keychain에 저장"), text: $proxyPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    editorLabel(AppText.string("Connect Timeout", korean: "연결 제한 시간"))
                    HStack {
                        TextField("15", text: $draft.connectTimeoutSeconds)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text(AppText.string("seconds", korean: "초"))
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    editorLabel(AppText.string("Keepalive", korean: "Keepalive"))
                    HStack {
                        TextField("30", text: $draft.keepaliveSeconds)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text(AppText.string("seconds", korean: "초"))
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    editorLabel(AppText.string("Reconnect", korean: "재연결"))
                    Toggle(AppText.string("Reconnect after unexpected disconnect", korean: "예기치 않게 연결이 끊기면 재연결"), isOn: $draft.autoReconnectEnabled)
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    editorLabel(AppText.string("Agent Forwarding", korean: "에이전트 포워딩"))
                    Toggle(AppText.string("Forward SSH agent", korean: "SSH 에이전트 전달"), isOn: $draft.agentForwardingEnabled)
                        .toggleStyle(.checkbox)
                }
            }
            .padding(.top, 10)
        } label: {
            Label(AppText.string("Advanced Connection Options", korean: "고급 연결 옵션"), systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var forwardingSection: some View {
        DisclosureGroup(isExpanded: $isForwardingExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppText.string(
                    "Loopback is prefilled for new TCP listeners. Choosing a non-loopback address explicitly exposes the listener.",
                    korean: "새 TCP listener에는 loopback이 기본으로 채워집니다. loopback 이외 주소를 선택하면 listener가 외부에 노출됩니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(draft.forwardingRules.indices, id: \.self) { index in
                    ProfileForwardingRuleEditor(
                        rule: $draft.forwardingRules[index],
                        onDelete: { draft.forwardingRules.remove(at: index) }
                    )
                }
                Button {
                    draft.forwardingRules.append(.blank())
                } label: {
                    Label(AppText.string("Add Forwarding Rule", korean: "포워딩 규칙 추가"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 10)
        } label: {
            Label(AppText.string("Port Forwarding", korean: "포트 포워딩"), systemImage: "arrow.left.arrow.right")
                .font(.headline)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var editorFooter: some View {
        HStack {
            if !isServiceAvailable {
                Label(AppText.unavailable, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(AppText.cancel, role: .cancel) {
                clearSecrets()
                dismiss()
            }
            Button(AppText.save) {
                var submissionDraft = draft
                submissionDraft.tags = normalizedTags
                onSave(ProfileEditorSubmission(
                    draft: submissionDraft,
                    secrets: ProfileEditorSecrets(
                        password: profilePassword,
                        privateKeyPassphrase: keyPassphrase,
                        proxyPassword: proxyPassword
                    )
                ))
                clearSecrets()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || !isServiceAvailable)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var availableJumpProfiles: [ProfilePresentation] {
        profiles.filter { $0.id != draft.id }
    }

    private var normalizedTags: [String] {
        Array(Set(tagText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var canSave: Bool {
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.isEmpty,
              !user.isEmpty,
              let port = Int(draft.port), (1 ... 65_535).contains(port)
        else {
            return false
        }
        if draft.proxyKind != .none {
            guard !draft.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let proxyPort = Int(draft.proxyPort), (1 ... 65_535).contains(proxyPort)
            else {
                return false
            }
        }
        switch draft.authenticationMethod {
        case .privateKey, .certificate:
            return !draft.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .sshAgent, .password, .keyboardInteractive:
            return true
        }
    }

    private func authenticationTitle(_ method: AuthenticationMethodPresentation) -> String {
        switch method {
        case .sshAgent: "SSH Agent"
        case .privateKey: AppText.string("Private Key", korean: "개인 키")
        case .password: AppText.string("Password", korean: "비밀번호")
        case .keyboardInteractive: "Keyboard-Interactive"
        case .certificate: AppText.string("Key and Certificate", korean: "키 및 인증서")
        }
    }

    private func jumpBinding(for profileID: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.jumpProfileIDs.contains(profileID) },
            set: { selected in
                if selected {
                    if !draft.jumpProfileIDs.contains(profileID) {
                        draft.jumpProfileIDs.append(profileID)
                    }
                } else {
                    draft.jumpProfileIDs.removeAll { $0 == profileID }
                }
            }
        )
    }

    private func editorLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(minWidth: 130, alignment: .trailing)
    }

    private func chooseFile(_ apply: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            apply(url)
        }
    }

    private func clearSecrets() {
        profilePassword.removeAll(keepingCapacity: false)
        keyPassphrase.removeAll(keepingCapacity: false)
        proxyPassword.removeAll(keepingCapacity: false)
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ProfileForwardingRuleEditor: View {
    @Binding var rule: ForwardingDraftPresentation
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(AppText.string("Rule name", korean: "규칙 이름"), text: $rule.name)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(AppText.delete)
            }
            HStack {
                Picker(AppText.string("Direction", korean: "방향"), selection: $rule.direction) {
                    ForEach(TunnelDirectionPresentation.allCases) { direction in
                        Text(directionTitle(direction)).tag(direction)
                    }
                }
                .labelsHidden()
                TextField(AppText.string("Bind address", korean: "바인드 주소"), text: $rule.bindAddress)
                    .textFieldStyle(.roundedBorder)
                TextField(AppText.string("Port or socket", korean: "포트 또는 소켓"), text: $rule.source)
                    .textFieldStyle(.roundedBorder)
            }
            TextField(AppText.string("Destination host:port or socket", korean: "대상 호스트:포트 또는 소켓"), text: $rule.destination)
                .textFieldStyle(.roundedBorder)
            Toggle(AppText.string("Keep running independently", korean: "독립적으로 계속 실행"), isOn: $rule.startIndependently)
                .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func directionTitle(_ direction: TunnelDirectionPresentation) -> String {
        switch direction {
        case .local: "Local (-L)"
        case .remote: "Remote (-R)"
        case .dynamic: "Dynamic SOCKS (-D)"
        case .remoteDynamic: AppText.string("Remote Dynamic", korean: "원격 Dynamic")
        case .localSocket: AppText.string("Local Socket", korean: "로컬 소켓")
        case .remoteSocket: AppText.string("Remote Socket", korean: "원격 소켓")
        }
    }
}
