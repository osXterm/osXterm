import AppKit

@MainActor
enum ApplicationTerminationCoordinator {
    weak static var model: AppWorkspaceModel?
}

@MainActor
final class OsXtermApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let model = ApplicationTerminationCoordinator.model else { return .terminateNow }
        guard model.hasActiveProcesses else {
            model.shutdownForTermination()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = AppText.string(
            "Disconnect active sessions and tunnels?",
            korean: "활성 세션과 터널을 종료할까요?"
        )
        alert.informativeText = AppText.string(
            "Quitting stops processes started by osXterm. Remote shells are not restored automatically when the app opens again.",
            korean: "종료하면 osXterm이 시작한 프로세스를 중지합니다. 앱을 다시 열어도 원격 셸은 자동으로 복구되지 않습니다."
        )
        alert.addButton(withTitle: AppText.string("Quit and Disconnect", korean: "종료 및 연결 해제"))
        alert.addButton(withTitle: AppText.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.shutdownForTermination()
        return .terminateNow
    }
}
