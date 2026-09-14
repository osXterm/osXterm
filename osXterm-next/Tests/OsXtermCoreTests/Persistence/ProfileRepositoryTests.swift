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
        #expect(text.uppercased().contains(secret.id.uuidString.uppercased()))
        #expect(!text.contains(secret.keychainAccount))
        #expect(!text.contains("not-a-real-password"))
        let restored = await repository.profile(id: profile.id)
        #expect(restored?.name == "test")
    }

    @Test func deletingJumpProfileCannotSilentlyBypassItsRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try ProfileRepository(fileURL: fileURL)
        let hop = ConnectionProfile(name: "hop", host: "jump", username: "ops")
        let target = ConnectionProfile(name: "target", host: "target", username: "ops", jumpProfileIDs: [hop.id])
        try await repository.save(hop)
        try await repository.save(target)
        await #expect(throws: ProfileRepositoryError.profileUsedAsJumpHost(dependentProfileNames: ["target"])) {
            try await repository.deleteProfile(id: hop.id)
        }

        let restored = try ProfileRepository(fileURL: fileURL)
        let profiles = await restored.profiles()
        let route = try SSHRouteResolver.resolve(targetID: target.id, profiles: profiles)
        #expect(route.hops.map(\.id) == [hop.id])
        #expect(await repository.profile(id: hop.id) != nil)
        #expect(await repository.profile(id: target.id)?.jumpProfileIDs == [hop.id])

        // Explicitly editing the dependent route is the only way to remove
        // that hop. Once that edit is saved, deletion is allowed.
        var editedTarget = target
        editedTarget.jumpProfileIDs = []
        try await repository.save(editedTarget)
        try await repository.deleteProfile(id: hop.id)
        #expect(await repository.profile(id: hop.id) == nil)
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

    @Test func failedSaveAndDeleteKeepTheLastCommittedProfileDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("storage", isDirectory: true)
        let savedDirectory = root.appendingPathComponent("saved-storage", isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProfileRepository(fileURL: fileURL)
        let folder = ConnectionFolder(name: "Production")
        let profile = ConnectionProfile(name: "api", folderID: folder.id, host: "api.internal", username: "ops")
        try await repository.saveFolder(folder)
        try await repository.save(profile)
        let committed = await repository.snapshot()
        let committedBytes = try Data(contentsOf: fileURL)

        // Replace the parent directory with a file to create a deterministic
        // write failure without depending on the test user's privileges.
        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        try Data("write blocked".utf8).write(to: directory)
        var edited = profile
        edited.host = "different.internal"
        await #expect(throws: AtomicJSONStoreError.self) { try await repository.save(edited) }
        await #expect(throws: AtomicJSONStoreError.self) { try await repository.deleteProfile(id: profile.id) }
        await #expect(throws: AtomicJSONStoreError.self) { try await repository.deleteFolder(id: folder.id) }
        let afterFailure = await repository.snapshot()
        #expect(afterFailure.profiles == committed.profiles)
        #expect(afterFailure.folders == committed.folders)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: savedDirectory, to: directory)
        #expect(try Data(contentsOf: fileURL) == committedBytes)
        let reopened = try ProfileRepository(fileURL: fileURL)
        #expect(await reopened.profile(id: profile.id)?.host == profile.host)
        #expect(await reopened.profile(id: profile.id)?.folderID == folder.id)
    }
}
