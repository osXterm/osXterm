import Foundation
import Testing
@testable import OsXtermCore

struct ProfileRepositoryTests {
    @Test func savesReferencesWithoutSecrets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try ProfileRepository(fileURL: fileURL)
        let secret = SecretReference()
        let profile = ConnectionProfile(
            name: "test",
            host: "server.internal",
            username: "deploy",
            authentication: .password(secret: secret)
        )
        try await repository.save(profile)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(text.contains(secret.id.uuidString.lowercased()))
        #expect(!text.contains("not-a-real-password"))
        let restored = await repository.profile(id: profile.id)
        #expect(restored?.name == "test")
    }

    @Test func deletingJumpProfileRemovesReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try ProfileRepository(fileURL: fileURL)
        let hop = ConnectionProfile(name: "hop", host: "jump", username: "ops")
        let target = ConnectionProfile(name: "target", host: "target", username: "ops", jumpProfileIDs: [hop.id])
        try await repository.save(hop)
        try await repository.save(target)
        try await repository.deleteProfile(id: hop.id)

        #expect(await repository.profile(id: target.id)?.jumpProfileIDs.isEmpty == true)
    }

    @Test func deletingFolderKeepsProfilesAndClearsTheirFolderReference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try ProfileRepository(fileURL: fileURL)
        let folder = ConnectionFolder(name: "Production", sortOrder: 2)
        let profile = ConnectionProfile(
            name: "api",
            folderID: folder.id,
            host: "api.internal",
            username: "deploy"
        )
        try await repository.saveFolder(folder)
        try await repository.save(profile)
        try await repository.deleteFolder(id: folder.id)

        let snapshot = await repository.snapshot()
        #expect(snapshot.folders.isEmpty)
        #expect(snapshot.profiles.first?.folderID == nil)
    }
}
