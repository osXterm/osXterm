import Foundation
import Testing
@testable import OsXTermCore

struct ProfileTests {
    @Test
    func profileRoundTripPreservesConnectionSettings() throws {
        let jumpHostID = UUID()
        let profile = SSHProfile(
            name: "Production",
            host: "server.example.com",
            username: "deploy",
            authentication: .agent(socketPath: "/tmp/agent.sock"),
            agentForwarding: true,
            jumpHostProfileIDs: [jumpHostID]
        )

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SSHProfile.self, from: encoded)

        #expect(decoded == profile)
    }

    @Test
    func legacyManualJumpFieldsDisappearOnRewrite() throws {
        let profile = SSHProfile(
            name: "Legacy",
            host: "server.example.com",
            username: "deploy",
            jumpHosts: [SSHJumpHost(host: "bastion.example.com", username: "jump")]
        )
        let rewritten = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(!rewritten.contains("jumpHosts"))
    }

    @Test
    func legacyPasswordReferenceMigratesToPromptOnlyAuthentication() throws {
        let legacy = Data(#"{"password":{"secretID":"legacy-reference"}}"#.utf8)

        let authentication = try JSONDecoder().decode(SSHAuthentication.self, from: legacy)
        let rewritten = try JSONEncoder().encode(authentication)

        #expect(authentication == .password)
        #expect(!String(decoding: rewritten, as: UTF8.self).contains("secretID"))
    }
}
