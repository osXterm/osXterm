import SwiftUI

@main
@MainActor
struct OsXTermApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    model.addProfile()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.isSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
