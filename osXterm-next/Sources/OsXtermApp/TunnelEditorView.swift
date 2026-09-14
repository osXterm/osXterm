import SwiftUI

struct TunnelEditorView: View {
    let request: TunnelEditorRequest
    let isServiceAvailable: Bool
    let onSave: (ForwardingDraftPresentation, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ForwardingDraftPresentation

    init(
        request: TunnelEditorRequest,
        isServiceAvailable: Bool,
        onSave: @escaping (ForwardingDraftPresentation, UUID?) -> Void
    ) {
        self.request = request
        self.isServiceAvailable = isServiceAvailable
        self.onSave = onSave
        _draft = State(initialValue: request.existing ?? .blank())
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.existing == nil ? AppText.string("New Tunnel", korean: "새 터널") : AppText.string("Edit Tunnel", korean: "터널 편집"))
                    .font(.title2.weight(.semibold))
                Text(AppText.string(
                    "Listener status reflects the actual OpenSSH result. It does not prove that the destination service is reachable.",
                    korean: "listener 상태는 실제 OpenSSH 결과를 반영합니다. 대상 서비스에 도달할 수 있다는 뜻은 아닙니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            Divider()

            Form {
                Section(AppText.string("Rule", korean: "규칙")) {
                    TextField(AppText.string("Name", korean: "이름"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                    Picker(AppText.string("Type", korean: "유형"), selection: $draft.direction) {
                        ForEach(TunnelDirectionPresentation.allCases) { direction in
                            Text(directionTitle(direction)).tag(direction)
                        }
                    }
                    .accessibilityLabel(AppText.string("Tunnel type", korean: "터널 유형"))
                }

                Section(AppText.string("Listener", korean: "리스너")) {
                    TextField(AppText.string("Bind Address", korean: "바인드 주소"), text: $draft.bindAddress)
                        .textFieldStyle(.roundedBorder)
                    TextField(sourcePrompt, text: $draft.source)
                        .textFieldStyle(.roundedBorder)
                    Text(AppText.string(
                        "Use 127.0.0.1 or ::1 unless external exposure is intentional. For a remote TCP listener, port 0 asks the server to allocate a port.",
                        korean: "외부 노출이 의도된 경우가 아니면 127.0.0.1 또는 ::1을 사용하세요. 원격 TCP listener에서는 포트 0을 사용해 서버가 포트를 할당하게 할 수 있습니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if needsDestination {
                    Section(AppText.string("Destination", korean: "대상")) {
                        TextField(destinationPrompt, text: $draft.destination)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section(AppText.string("Lifecycle", korean: "수명주기")) {
                    Toggle(AppText.string("Run independently from a terminal tab", korean: "터미널 탭과 독립적으로 실행"), isOn: $draft.startIndependently)
                        .toggleStyle(.checkbox)
                    Text(AppText.string(
                        "Independent tunnels remain manageable from the menu bar while the app is running.",
                        korean: "독립 터널은 앱이 실행 중인 동안 메뉴 막대에서 관리할 수 있습니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 16)

            Divider()
            HStack {
                Spacer()
                Button(AppText.cancel, role: .cancel) { dismiss() }
                Button(AppText.save) {
                    onSave(draft, request.sessionID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isServiceAvailable || !isValid)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .accessibilityLabel(AppText.string("Tunnel editor", korean: "터널 편집기"))
    }

    private var needsDestination: Bool {
        switch draft.direction {
        case .dynamic, .remoteDynamic:
            false
        case .local, .remote, .localSocket, .remoteSocket:
            true
        }
    }

    private var sourcePrompt: String {
        switch draft.direction {
        case .local, .remote, .dynamic, .remoteDynamic:
            AppText.string("Listener port or 0", korean: "listener 포트 또는 0")
        case .localSocket, .remoteSocket:
            AppText.string("Listener socket path", korean: "listener 소켓 경로")
        }
    }

    private var destinationPrompt: String {
        switch draft.direction {
        case .local, .remote:
            AppText.string("Destination host:port", korean: "대상 호스트:포트")
        case .localSocket, .remoteSocket:
            AppText.string("Destination socket path", korean: "대상 소켓 경로")
        case .dynamic, .remoteDynamic:
            ""
        }
    }

    private var isValid: Bool {
        let source = draft.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return false }
        if needsDestination {
            return !draft.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
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
