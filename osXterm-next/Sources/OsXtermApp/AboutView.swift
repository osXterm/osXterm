import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Text("osXterm")
                .font(.title.bold())
            Text(AppText.string("Native SSH workspace for macOS", korean: "macOS용 네이티브 SSH 작업 공간"))
                .foregroundStyle(.secondary)
            Text(version)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(AppText.string("Licenses", korean: "라이선스"))
                    .font(.headline)
                Text(AppText.string(
                    "osXterm is distributed under the MIT License. It includes SwiftTerm 1.19.0 and bundled terminal-font notices in its third-party resources.",
                    korean: "osXterm은 MIT License로 배포됩니다. SwiftTerm 1.19.0과 번들 터미널 글꼴의 제3자 고지가 앱 리소스에 포함됩니다."
                ))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(AppText.string("Done", korean: "완료")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(26)
        .frame(width: 420)
        .accessibilityLabel(AppText.string("About osXterm", korean: "osXterm 정보"))
    }
}
