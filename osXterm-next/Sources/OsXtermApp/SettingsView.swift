import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettingsPresentation

    init(model: AppWorkspaceModel) {
        self.model = model
        _draft = State(initialValue: model.snapshot.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalSettings
                    .tabItem {
                        Label(AppText.string("General", korean: "일반"), systemImage: "gearshape")
                    }
                terminalSettings
                    .tabItem {
                        Label(AppText.string("Terminal", korean: "터미널"), systemImage: "terminal")
                    }
                securitySettings
                    .tabItem {
                        Label(AppText.string("Security", korean: "보안"), systemImage: "lock.shield")
                    }
            }
            .padding(20)
            Divider()
            HStack {
                if !model.isServiceAvailable {
                    Label(AppText.unavailable, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppText.cancel, role: .cancel) { dismiss() }
                Button(AppText.save) {
                    model.updateSettings(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isServiceAvailable || !isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear {
            draft = model.snapshot.settings
        }
        .accessibilityLabel(AppText.settings)
    }

    private var generalSettings: some View {
        Form {
            Section(AppText.string("Appearance", korean: "모양")) {
                Picker(AppText.string("Appearance", korean: "모양"), selection: $draft.appearance) {
                    Text(AppText.string("System", korean: "시스템")).tag(AppSettingsPresentation.Appearance.system)
                    Text(AppText.string("Light", korean: "라이트")).tag(AppSettingsPresentation.Appearance.light)
                    Text(AppText.string("Dark", korean: "다크")).tag(AppSettingsPresentation.Appearance.dark)
                }
                .accessibilityLabel(AppText.string("Appearance", korean: "모양"))
            }

            Section(AppText.string("Window and Tunnels", korean: "창 및 터널")) {
                Toggle(
                    AppText.string("Keep independent tunnels running when the window closes", korean: "창을 닫아도 독립 터널 계속 실행"),
                    isOn: $draft.keepTunnelsRunningWhenWindowCloses
                )
                Text(AppText.string(
                    "The app asks before quitting when active connections or tunnels still need cleanup.",
                    korean: "활성 연결이나 터널을 정리해야 하는 경우 앱 종료 전에 확인합니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var terminalSettings: some View {
        Form {
            Section(AppText.string("Typography", korean: "글꼴")) {
                TextField(AppText.string("Font", korean: "글꼴"), text: $draft.terminalFontName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(AppText.string("Terminal font", korean: "터미널 글꼴"))
                HStack {
                    Text(AppText.string("Font Size", korean: "글꼴 크기"))
                    Slider(value: $draft.terminalFontSize, in: 9 ... 28, step: 1)
                    Text("\(Int(draft.terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
                HStack {
                    Text(AppText.string("Line Spacing", korean: "줄 간격"))
                    Slider(value: $draft.terminalLineSpacing, in: 1 ... 1.6, step: 0.05)
                    Text(String(format: "%.2f", draft.terminalLineSpacing))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section(AppText.string("Theme and Logging", korean: "테마 및 로그")) {
                TextField(AppText.string("Theme", korean: "테마"), text: $draft.terminalThemeName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(AppText.string("Terminal theme", korean: "터미널 테마"))
                Toggle(AppText.string("Record session logs", korean: "세션 로그 기록"), isOn: $draft.sessionLoggingEnabled)
                Text(AppText.string(
                    "Logs are opt-in. Review the selected log location before exporting or sharing them.",
                    korean: "로그 기록은 사용자가 선택한 경우에만 합니다. 내보내거나 공유하기 전에 저장 위치를 확인하세요."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var securitySettings: some View {
        Form {
            Section(AppText.string("Remote Clipboard", korean: "원격 클립보드")) {
                Toggle(
                    AppText.string("Allow remote applications to use the clipboard through OSC 52", korean: "원격 앱의 OSC 52 클립보드 접근 허용"),
                    isOn: $draft.allowRemoteClipboard
                )
                Text(AppText.string(
                    "Disabled by default. Enabling this lets a remote terminal read from and write to your system clipboard.",
                    korean: "기본값은 비활성화입니다. 허용하면 원격 터미널이 시스템 클립보드를 읽고 쓸 수 있습니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(AppText.string("Credentials and Host Keys", korean: "자격 증명 및 호스트 키")) {
                Label(AppText.string("Passwords and passphrases use Keychain references.", korean: "비밀번호와 암호 문구는 Keychain 참조를 사용합니다."), systemImage: "key.fill")
                Label(AppText.string("Unknown and changed host keys require a review before connecting.", korean: "알 수 없거나 변경된 호스트 키는 연결 전에 검토가 필요합니다."), systemImage: "checkmark.shield")
            }
        }
        .formStyle(.grouped)
    }

    private var isValid: Bool {
        !draft.terminalFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (9 ... 28).contains(draft.terminalFontSize)
            && (1 ... 1.6).contains(draft.terminalLineSpacing)
    }
}
