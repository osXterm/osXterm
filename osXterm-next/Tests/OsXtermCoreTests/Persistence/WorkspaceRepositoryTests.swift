import Foundation
import Testing
@testable import OsXtermCore

struct WorkspaceRepositoryTests {
    @Test
    func persistsSettingsAndWorkspaceLayoutAtomically() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("workspace.json")
        let repository = try WorkspaceRepository(fileURL: fileURL)

        let firstSession = TerminalSessionDescriptor(
            title: "Operations",
            kind: .profile(UUID()),
            shouldLog: true
        )
        let secondSession = TerminalSessionDescriptor(
            title: "Local",
            kind: .localShell
        )
        let workspace = WorkspaceSnapshot(
            name: "Daily work",
            sessions: [firstSession, secondSession],
            layout: .split(
                axis: .vertical,
                ratio: 0.55,
                leading: .session(firstSession.id),
                trailing: .session(secondSession.id)
            ),
            selectedSessionID: secondSession.id
        )
        let settings = AppSettings(
            appearance: .dark,
            terminalFontName: "D2Coding",
            terminalFontSize: 15,
            terminalLineSpacing: 1.2,
            terminalThemeName: "Dracula",
            allowRemoteClipboard: true,
            keepTunnelsRunningWhenWindowCloses: false,
            sessionLoggingEnabled: true
        )

        try await repository.updateWorkspace(workspace)
        try await repository.updateSettings(settings)

        let restoredRepository = try WorkspaceRepository(fileURL: fileURL)
        let restored = await restoredRepository.snapshot()
        #expect(restored.settings == settings)
        #expect(restored.workspace.name == workspace.name)
        #expect(restored.workspace.sessions == workspace.sessions)
        #expect(restored.workspace.layout == workspace.layout)
        #expect(restored.workspace.selectedSessionID == secondSession.id)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func rejectsUnknownWorkspaceDocumentVersion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("workspace.json")
        let unsupportedDocument = AppWorkspaceDocument(
            version: AppWorkspaceDocument.currentVersion + 1
        )
        try AtomicJSONStore<AppWorkspaceDocument>(fileURL: fileURL).save(unsupportedDocument)

        #expect(throws: AtomicJSONStoreError.self) {
            _ = try WorkspaceRepository(fileURL: fileURL)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
