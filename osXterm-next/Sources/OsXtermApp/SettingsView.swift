import AppKit
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
                Picker(AppText.string("Font", korean: "글꼴"), selection: terminalFont) {
                    ForEach(TerminalFont.allCases) { font in
                        Text(font.displayName).tag(font)
                    }
                }
                    .accessibilityLabel(AppText.string("Terminal font", korean: "터미널 글꼴"))
                Text(AppText.string(
                    "osXterm includes these terminal fonts in the app and does not use the macOS font collection for this setting.",
                    korean: "이 터미널 글꼴은 osXterm 앱에 포함되어 있으며, 이 설정에서는 macOS 글꼴 목록을 사용하지 않습니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Picker(AppText.string("Theme", korean: "테마"), selection: terminalTheme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                    .accessibilityLabel(AppText.string("Terminal theme", korean: "터미널 테마"))
                Text(AppText.string(
                    "System follows the current macOS appearance. The other 19 built-in themes include their own ANSI palette.",
                    korean: "시스템은 현재 macOS 모양을 따릅니다. 나머지 19개 내장 테마에는 전용 ANSI 팔레트가 포함됩니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle(AppText.string("Record session logs", korean: "세션 로그 기록"), isOn: $draft.sessionLoggingEnabled)
                Text(AppText.string(
                    "Logs are opt-in and the setting applies to active and future sessions. Review the selected log location before exporting or sharing them.",
                    korean: "로그 기록은 사용자가 선택한 경우에만 하며, 현재와 이후 세션에 적용됩니다. 내보내거나 공유하기 전에 저장 위치를 확인하세요."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(AppText.string("Terminal Preview", korean: "터미널 미리보기")) {
                TerminalAppearancePreview(
                    fontName: draft.terminalFontName,
                    fontSize: draft.terminalFontSize,
                    lineSpacing: draft.terminalLineSpacing,
                    themeName: draft.terminalThemeName,
                    appearance: draft.appearance
                )
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
        (9 ... 28).contains(draft.terminalFontSize)
            && (1 ... 1.6).contains(draft.terminalLineSpacing)
    }

    private var terminalFont: Binding<TerminalFont> {
        Binding(
            get: { TerminalFont(persistedName: draft.terminalFontName) },
            set: { draft.terminalFontName = $0.rawValue }
        )
    }

    private var terminalTheme: Binding<TerminalTheme> {
        Binding(
            get: { TerminalTheme(persistedName: draft.terminalThemeName) },
            set: { draft.terminalThemeName = $0.rawValue }
        )
    }
}

private struct TerminalAppearancePreview: View {
    let fontName: String
    let fontSize: Double
    let lineSpacing: Double
    let themeName: String
    let appearance: AppSettingsPresentation.Appearance

    private var terminalTheme: TerminalTheme {
        TerminalTheme(persistedName: themeName)
    }

    private var previewAppearance: NSAppearance {
        switch appearance {
        case .system:
            NSApp.effectiveAppearance
        case .light:
            NSAppearance(named: .aqua) ?? NSApp.effectiveAppearance
        case .dark:
            NSAppearance(named: .darkAqua) ?? NSApp.effectiveAppearance
        }
    }

    private var visualStyle: TerminalThemeVisualStyle {
        TerminalThemeVisualStyle.resolve(terminalTheme, appearance: previewAppearance)
    }

    private var selectedFont: TerminalFont {
        TerminalFont(persistedName: fontName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: visualStyle.caret))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("\(terminalTheme.displayName)  \(selectedFont.displayName)")
                    .font(.caption.weight(.medium))
            }

            Text("dev@osxterm ~ % ssh admin@bastion")
            Text("한글 입력  emoji  UTF-8")
            Text("$ git status")
        }
        .font(.custom(selectedFont.regularPostScriptName, size: fontSize))
        .lineSpacing(max(0, lineSpacing - 1))
        .foregroundStyle(Color(nsColor: visualStyle.foreground))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: visualStyle.background), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: visualStyle.selectionBackground).opacity(0.75))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppText.string(
            "Terminal appearance preview using \(terminalTheme.displayName) and \(selectedFont.displayName)",
            korean: "\(terminalTheme.displayName) 및 \(selectedFont.displayName) 터미널 모양 미리보기"
        ))
    }
}
