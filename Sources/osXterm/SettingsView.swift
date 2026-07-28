import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalFontConfiguration) private var ghosttyFontConfiguration
    @Binding var appearancePreference: AppAppearancePreference
    @Binding var terminalThemeID: String
    @Binding var terminalFontSize: Double
    @Binding var ghosttyConfigurationPath: String
    let terminalThemes: [GhosttyTerminalTheme]
    let onReloadGhosttyConfig: () -> Void
    let onOpenGhosttySettings: () -> Void
    let onTerminalFontSizeChanged: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearancePreference) {
                        ForEach(AppAppearancePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    Text("This changes the osXterm interface. The Ghostty terminal theme is configured separately below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Application", systemImage: "macwindow")
                }

                Section {
                    Picker("Terminal theme", selection: $terminalThemeID) {
                        ForEach(terminalThemes) { theme in
                            Text(theme.title).tag(theme.id)
                        }
                    }
                    if let selected = terminalThemes.first(where: { $0.id == terminalThemeID }) {
                        Text("\(selected.source)\n\(terminalThemes.count - 1) Ghostty themes available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("This setting changes the embedded Ghostty terminal only. Themes and font settings are read from Ghostty configuration and theme directories.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Open Ghostty settings", action: onOpenGhosttySettings)
                        Button("Reload configuration", action: onReloadGhosttyConfig)
                    }
                    LabeledContent("Configuration file") {
                        TextField(
                            text: $ghosttyConfigurationPath,
                            prompt: Text("~/.config/ghostty/config")
                        ) {}
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Ghostty configuration file path")
                    }
                    Text("The path is used when Reload configuration is pressed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Font family: \(ghosttyFontConfiguration.displayFamily)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Font size")
                            Spacer()
                            Text("\(Int(terminalFontSize.rounded())) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { terminalFontSize },
                                set: {
                                    terminalFontSize = $0
                                    onTerminalFontSizeChanged()
                                }
                            ),
                            in: AppModel.terminalFontSizeRange,
                            step: 1
                        ) {
                            Text("Terminal font size")
                        } minimumValueLabel: {
                            Text("10")
                                .font(.caption2)
                        } maximumValueLabel: {
                            Text("24")
                                .font(.caption2)
                        }
                        Text(ghosttyFontConfiguration.displayFamily)
                            .font(TerminalAppearance.terminalFont(
                                size: terminalFontSize,
                                configuration: ghosttyFontConfiguration
                            ))
                            .foregroundStyle(.secondary)
                        if ghosttyFontConfiguration.primaryFamily == nil {
                            Text("Ghostty default font")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Font family follows Ghostty configuration")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("Ghostty terminal", systemImage: "terminal")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 560, height: 460)
    }
}
