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

    @Test
    func failedSettingsSaveDoesNotBecomeALaterSuccessfulWorkspaceSave() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("storage", isDirectory: true)
        let savedDirectory = root.appendingPathComponent("saved-storage", isDirectory: true)
        let fileURL = directory.appendingPathComponent("workspace.json")
        let repository = try WorkspaceRepository(fileURL: fileURL)
        var committedSettings = AppSettings()
        committedSettings.terminalThemeName = "Nord"
        try await repository.updateSettings(committedSettings)

        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        try Data("write blocked".utf8).write(to: directory)
        var unsavedSettings = committedSettings
        unsavedSettings.terminalThemeName = "Dracula"
        await #expect(throws: AtomicJSONStoreError.self) {
            try await repository.updateSettings(unsavedSettings)
        }
        #expect(await repository.snapshot().settings == committedSettings)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: savedDirectory, to: directory)
        // A later successful operation must not persist the rejected edit.
        let recentProfileID = UUID()
        try await repository.noteRecentProfile(recentProfileID)
        let reopened = try WorkspaceRepository(fileURL: fileURL)
        let restored = await reopened.snapshot()
        #expect(restored.settings == committedSettings)
        #expect(restored.recentProfileIDs == [recentProfileID])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
