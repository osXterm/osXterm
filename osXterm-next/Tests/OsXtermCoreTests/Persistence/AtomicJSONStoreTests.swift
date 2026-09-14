import Foundation
import Testing
@testable import OsXtermCore

struct AtomicJSONStoreTests {
    @Test
    func replacementPreservesPrivateModeAndLeavesNoStagingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("profiles.json")
        let store = AtomicJSONStore<ProfileDocument>(fileURL: fileURL)
        try store.save(ProfileDocument())
        // A pre-existing file may come from a backup with broader permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let profile = ConnectionProfile(name: "Saved", host: "saved.internal", username: "ops")
        try store.save(ProfileDocument(profiles: [profile]))

        let restored = try store.load(default: ProfileDocument())
        #expect(restored.profiles.map(\.id) == [profile.id])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(children == ["profiles.json"])
    }
}
