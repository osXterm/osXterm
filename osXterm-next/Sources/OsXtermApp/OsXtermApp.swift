import AppKit
import SwiftUI

@main
@MainActor
struct OsXtermApp: App {
    @StateObject private var model: AppWorkspaceModel
    @State private var isAboutPresented = false
    @NSApplicationDelegateAdaptor(OsXtermApplicationDelegate.self) private var applicationDelegate

    init() {
        BundledTerminalFontRegistry.registerBundledFonts()
        let workspaceModel = AppWorkspaceModel(service: AppRuntime.makeWorkspaceService())
        ApplicationTerminationCoordinator.model = workspaceModel
        _model = StateObject(wrappedValue: workspaceModel)
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView(model: model)
                .frame(minWidth: 1_080, minHeight: 720)
                .sheet(isPresented: $isAboutPresented) {
                    AboutView()
                }
        }
        .defaultSize(width: 1_420, height: 920)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(AppText.string("About osXterm", korean: "osXterm 정보")) {
                    isAboutPresented = true
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(AppText.newConnection) {
                    model.beginNewProfile()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!model.isServiceAvailable)

                Button(AppText.localTerminal) {
                    model.startLocalTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!model.isServiceAvailable)
            }

            CommandMenu(AppText.string("Session", korean: "세션")) {
                Button(AppText.string("Open Another SSH Session", korean: "같은 프로필로 SSH 세션 추가")) {
                    if let profileID = model.selectedSession?.profileID {
                        model.connect(profileID: profileID)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedSession?.profileID == nil || !model.isServiceAvailable)

                Button(AppText.string("Close Tab", korean: "탭 닫기")) {
                    if let session = model.selectedSession {
                        model.closeSession(id: session.id)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(model.selectedSession == nil || !model.isServiceAvailable)

                Divider()

                Button(AppText.string("Single Pane", korean: "단일 패널")) {
                    model.setLayout(.single)
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .disabled(!model.isServiceAvailable)

                Button(AppText.string("Split Horizontally", korean: "가로 분할")) {
                    model.setLayout(.horizontalSplit)
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(!model.isServiceAvailable)

                Button(AppText.string("Split Vertically", korean: "세로 분할")) {
                    model.setLayout(.verticalSplit)
                }
                .keyboardShortcut("3", modifiers: [.command, .shift])
                .disabled(!model.isServiceAvailable)
            }

            CommandMenu(AppText.tunnels) {
                Button(AppText.string("New Tunnel", korean: "새 터널")) {
                    model.beginNewTunnel(for: model.selectedSession?.id)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.isServiceAvailable)
            }
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra("osXterm", systemImage: activeTunnelCount == 0 ? "terminal" : "point.3.connected.trianglepath.dotted") {
            if activeTunnelCount == 0 {
                Text(AppText.string("No active independent tunnels", korean: "활성 독립 터널 없음"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeTunnels) { tunnel in
                    Button {
                        model.stopTunnel(id: tunnel.id)
                    } label: {
                        Label(
                            "\(tunnel.name)  \(tunnel.listeningEndpoint ?? "")",
                            systemImage: "stop.circle"
                        )
                    }
                }
            }
            Divider()
            Button(AppText.string("Show osXterm", korean: "osXterm 표시")) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var activeTunnels: [TunnelPresentation] {
        model.snapshot.tunnels.filter {
            $0.isIndependent && ($0.phase == .starting || $0.phase == .listening || $0.phase == .stopping)
        }
    }

    private var activeTunnelCount: Int { activeTunnels.count }
}

@MainActor
enum AppRuntime {
    static func makeWorkspaceService() -> any AppWorkspaceService {
        do {
            return try CoreWorkspaceService()
        } catch {
            return UnconfiguredWorkspaceService(reason: error.localizedDescription)
        }
    }
}
