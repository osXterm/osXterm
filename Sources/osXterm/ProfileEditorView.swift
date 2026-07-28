import AppKit
import OsXTermCore
import SwiftUI

private enum AuthenticationMode: String, CaseIterable, Identifiable {
    case agent = "SSH Agent"
    case identityFile = "Key File"
    case password = "Password"

    var id: String { rawValue }
}

private enum ProxyMode: String, CaseIterable, Identifiable {
    case none = "None"
    case http = "HTTP CONNECT"
    case socks5 = "SOCKS5"

    var id: String { rawValue }
}

private enum ProfileEditorField: Hashable {
    case name
    case host
    case username
    case port
    case agentSocket
    case identityPath
    case password
    case proxyHost
    case proxyPort
    case proxyUsername
}

struct ProfileEditorView: View {
    @State private var draft: SSHProfile
    @State private var authenticationMode: AuthenticationMode
    @State private var authenticationPath: String
    @State private var proxyMode: ProxyMode
    @State private var proxyHost: String
    @State private var portText: String
    @State private var proxyPortText: String
    @State private var proxyUsername: String
    @State private var password = ""
    @State private var shouldClearSavedPassword = false
    @State private var validationError: String?
    @State private var selectedJumpHostIDs: Set<UUID>
    @FocusState private var focusedField: ProfileEditorField?

    let profiles: [SSHProfile]
    let onSave: (SSHProfile) -> Void
    let onCancel: () -> Void

    init(
        profile: SSHProfile,
        profiles: [SSHProfile] = [],
        onSave: @escaping (SSHProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        _portText = State(initialValue: profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : String(profile.port))
        _selectedJumpHostIDs = State(initialValue: Set(profile.jumpHostProfileIDs))
        self.profiles = profiles
        self.onSave = onSave
        self.onCancel = onCancel

        switch profile.proxy {
        case .none:
            _proxyMode = State(initialValue: .none)
            _proxyHost = State(initialValue: "")
            _proxyPortText = State(initialValue: "")
            _proxyUsername = State(initialValue: "")
        case let .http(host, port, username):
            _proxyMode = State(initialValue: .http)
            _proxyHost = State(initialValue: host)
            _proxyPortText = State(initialValue: String(port))
            _proxyUsername = State(initialValue: username ?? "")
        case let .socks5(host, port, username):
            _proxyMode = State(initialValue: .socks5)
            _proxyHost = State(initialValue: host)
            _proxyPortText = State(initialValue: String(port))
            _proxyUsername = State(initialValue: username ?? "")
        }

        switch profile.authentication {
        case let .agent(socketPath):
            _authenticationMode = State(initialValue: .agent)
            _authenticationPath = State(initialValue: socketPath ?? "")
        case let .identityFile(path):
            _authenticationMode = State(initialValue: .identityFile)
            _authenticationPath = State(initialValue: path)
        case .password:
            _authenticationMode = State(initialValue: .password)
            _authenticationPath = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        hintedTextField(
                            "e.g. Production",
                            text: $draft.name,
                            field: .name,
                            accessibilityLabel: "Name"
                        )
                    }
                    HStack {
                        LabeledContent("Host") {
                            hintedTextField(
                                "server.example.com",
                                text: $draft.host,
                                field: .host,
                                accessibilityLabel: "Host"
                            )
                        }
                        LabeledContent("Port") {
                            hintedTextField(
                                "22",
                                text: $portText,
                                field: .port,
                                accessibilityLabel: "Port"
                            )
                                .frame(width: 90)
                        }
                    }
                    LabeledContent("Username") {
                        hintedTextField(
                            "e.g. deploy",
                            text: $draft.username,
                            field: .username,
                            accessibilityLabel: "Username"
                        )
                    }
                } header: {
                    Label("Connection", systemImage: "server.rack")
                } footer: {
                    Text("Username is sent literally. Host is taken from the separate Host field.")
                }

                Section {
                    Picker("Method", selection: $authenticationMode) {
                        ForEach(AuthenticationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    authenticationConfiguration

                    Toggle("Forward SSH agent", isOn: $draft.agentForwarding)
                        .disabled(authenticationMode == .password)
                } header: {
                    Label("Authentication", systemImage: "key.fill")
                }

                Section {
                    Picker("Proxy", selection: $proxyMode) {
                        ForEach(ProxyMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if proxyMode != .none {
                        LabeledContent("Host") {
                            hintedTextField(
                                "proxy.example.com",
                                text: $proxyHost,
                                field: .proxyHost,
                                accessibilityLabel: "Proxy host"
                            )
                        }
                        HStack {
                            LabeledContent("Port") {
                                hintedTextField(
                                    "8080",
                                    text: $proxyPortText,
                                    field: .proxyPort,
                                    accessibilityLabel: "Proxy port"
                                )
                                    .frame(width: 90)
                            }
                            LabeledContent("Username") {
                                hintedTextField(
                                    "optional",
                                    text: $proxyUsername,
                                    field: .proxyUsername,
                                    accessibilityLabel: "Proxy username"
                                )
                            }
                        }
                        Text("Proxy transport is shared by SSH and Files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Proxy", systemImage: "network")
                }

                Section {
                    if jumpCandidates.isEmpty {
                        ContentUnavailableView(
                            "No other saved servers",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    } else {
                        List(jumpCandidates, selection: $selectedJumpHostIDs) { profile in
                            HStack {
                                Label(profile.name, systemImage: "server.rack")
                                Spacer()
                                Text(endpointText(profile))
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .tag(profile.id)
                            .disabled(!selectedJumpHostIDs.contains(profile.id) && !canSelectJumpHost(profile))
                        }
                        .frame(minHeight: 100, maxHeight: 180)
                    }
                } header: {
                    Label("Jump Hosts", systemImage: "arrow.triangle.branch")
                } footer: {
                    Text("Select saved servers in connection order. Their address and authentication settings stay live references.")
                }
            }
            .formStyle(.grouped)
            .onChange(of: authenticationMode) { _, mode in
                if mode == .password { focusedField = .password }
            }
            .onAppear {
                if authenticationMode == .password { focusedField = .password }
            }

            Divider()
            HStack {
                Label("Passwords are encrypted before saving.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glass)
                    .disabled(!isDraftValid)
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 650)
        .alert(
            "Unable to save connection",
            isPresented: Binding(
                get: { validationError != nil },
                set: { _ in validationError = nil }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationError ?? "")
        }
    }

    @ViewBuilder
    private var authenticationConfiguration: some View {
        switch authenticationMode {
        case .agent:
            LabeledContent("Agent socket") {
                hintedTextField(
                    "SSH_AUTH_SOCK or /tmp/agent.sock",
                    text: $authenticationPath,
                    field: .agentSocket,
                    accessibilityLabel: "Agent socket"
                )
            }
            Text("Leave blank to use SSH_AUTH_SOCK.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .identityFile:
            LabeledContent("Identity file") {
                HStack {
                    hintedTextField(
                        "~/.ssh/id_ed25519",
                        text: $authenticationPath,
                        field: .identityPath,
                        accessibilityLabel: "Identity file"
                    )
                    Button("Choose", action: chooseIdentityFile)
                }
            }
            Text("Key passphrases remain managed by the SSH agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .password:
            LabeledContent("Password") {
                VStack(alignment: .leading, spacing: 8) {
                    hintedSecureField(
                        "Enter password or leave blank",
                        text: $password,
                        field: .password,
                        accessibilityLabel: "Password"
                    )
                        .onChange(of: password) { _, value in
                            if !value.isEmpty { shouldClearSavedPassword = false }
                        }
                    if shouldClearSavedPassword {
                        Label("Saved password will be deleted on save", systemImage: "trash")
                            .foregroundStyle(.red)
                    } else if !password.isEmpty {
                        Label("New password will replace the saved value", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.tint)
                    } else if draft.encryptedPassword != nil {
                        HStack {
                            Label("Encrypted password saved", systemImage: "checkmark.shield")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Clear") {
                                shouldClearSavedPassword = true
                                focusedField = .password
                            }
                        }
                    } else {
                        Text("Leave blank to ask when connecting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var jumpCandidates: [SSHProfile] {
        profiles.filter { $0.id != draft.id }
    }

    private var isDraftValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && SSHConnectionTarget.parse(host: draft.host, username: draft.username) != nil
            && portValue.map { (1 ... 65_535).contains($0) } == true
            && isProxyDraftValid
    }

    private var isProxyDraftValid: Bool {
        guard proxyMode != .none else { return true }
        let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsControl: (String) -> Bool = { value in
            value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            }
        }
        return !host.isEmpty
            && proxyPortValue.map { (1 ... 65_535).contains($0) } == true
            && !containsControl(host)
            && (username.isEmpty || !containsControl(username))
    }

    private func save() {
        guard let port = portValue, (1 ... 65_535).contains(port) else {
            validationError = "Enter a valid port from 1 to 65535."
            return
        }
        guard let parsedTarget = SSHConnectionTarget.parse(host: draft.host, username: draft.username) else {
            return
        }
        draft.host = parsedTarget.host
        draft.username = parsedTarget.username
        draft.port = port
        draft.jumpHostProfileIDs = orderedJumpHostIDs()

        switch proxyMode {
        case .none:
            draft.proxy = nil
        case .http:
            guard let proxy = makeProxy(kind: .http) else { return }
            draft.proxy = proxy
        case .socks5:
            guard let proxy = makeProxy(kind: .socks5) else { return }
            draft.proxy = proxy
        }

        switch authenticationMode {
        case .agent:
            draft.authentication = .agent(socketPath: authenticationPath.isEmpty ? nil : authenticationPath)
            draft.encryptedPassword = nil
        case .identityFile:
            guard !authenticationPath.isEmpty else {
                validationError = "Choose a private key file or select another authentication method."
                return
            }
            draft.authentication = .identityFile(path: authenticationPath)
            draft.encryptedPassword = nil
        case .password:
            draft.authentication = .password
            if shouldClearSavedPassword {
                draft.encryptedPassword = nil
            } else if !password.isEmpty {
                do {
                    draft.encryptedPassword = try ProfilePasswordCipher.shared.encrypt(password)
                } catch {
                    validationError = error.localizedDescription
                    return
                }
            }
        }

        var candidateProfiles = profiles.filter { $0.id != draft.id }
        candidateProfiles.append(draft)
        do {
            _ = try SSHRouteResolver.resolve(target: draft, profiles: candidateProfiles)
            onSave(draft)
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        authenticationPath = url.path
    }

    private var portValue: Int? {
        let value = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? 22 : Int(value)
    }

    private var proxyPortValue: Int? {
        let value = proxyPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? 8080 : Int(value)
    }

    @ViewBuilder
    private func hintedTextField(
        _ placeholder: String,
        text: Binding<String>,
        field: ProfileEditorField,
        accessibilityLabel: String
    ) -> some View {
        TextField(
            "",
            text: text,
            prompt: Text(placeholder).foregroundStyle(.secondary)
        )
        .focused($focusedField, equals: field)
        .accessibilityLabel(accessibilityLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hintedSecureField(
        _ placeholder: String,
        text: Binding<String>,
        field: ProfileEditorField,
        accessibilityLabel: String
    ) -> some View {
        SecureField(
            "",
            text: text,
            prompt: Text(placeholder).foregroundStyle(.secondary)
        )
        .focused($focusedField, equals: field)
        .accessibilityLabel(accessibilityLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func endpointText(_ profile: SSHProfile) -> String {
        let target = SSHConnectionTarget.parse(host: profile.host, username: profile.username)
            ?? SSHConnectionTarget(username: profile.username, host: profile.host)
        return "\(target.username)@\(target.host):\(profile.port)"
    }

    private func makeProxy(kind: ProxyMode) -> SSHProxy? {
        let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsControl: (String) -> Bool = { value in
            value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            }
        }
        guard !host.isEmpty,
              let port = proxyPortValue,
              (1 ... 65_535).contains(port),
              !containsControl(host),
              username.isEmpty || !containsControl(username)
        else {
            validationError = "Enter a valid proxy host, port, and optional username."
            return nil
        }
        switch kind {
        case .http:
            return .http(host: host, port: port, username: username.isEmpty ? nil : username)
        case .socks5:
            return .socks5(host: host, port: port, username: username.isEmpty ? nil : username)
        case .none:
            return nil
        }
    }

    private func orderedJumpHostIDs(adding id: UUID? = nil) -> [UUID] {
        var selected = selectedJumpHostIDs
        if let id { selected.insert(id) }
        var ordered = draft.jumpHostProfileIDs.filter(selected.contains)
        let visibleOrder = jumpCandidates.map(\.id)
        ordered.append(contentsOf: visibleOrder.filter { selected.contains($0) && !ordered.contains($0) })
        return ordered
    }

    private func canSelectJumpHost(_ candidate: SSHProfile) -> Bool {
        var candidateDraft = draft
        candidateDraft.jumpHostProfileIDs = orderedJumpHostIDs(adding: candidate.id)
        var candidateProfiles = profiles.filter { $0.id != draft.id }
        candidateProfiles.append(candidateDraft)
        do {
            _ = try SSHRouteResolver.resolve(target: candidateDraft, profiles: candidateProfiles)
            return true
        } catch {
            return false
        }
    }
}
