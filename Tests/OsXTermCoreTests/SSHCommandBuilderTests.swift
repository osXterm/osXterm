import Foundation
import Testing
@testable import OsXTermCore

struct SSHCommandBuilderTests {
    @Test
    func preservesLiteralUsernameWhenHostIsSeparate() throws {
        let profile = SSHProfile(name: "Realm endpoint", host: "10.173.11.15", username: "hwjeong@sysadmin@10.171.30.22")
        let command = try SSHCommandBuilder().build(for: profile)
        #expect(optionValue(after: "-l", in: command.arguments) == "hwjeong@sysadmin@10.171.30.22")
        #expect(command.arguments.suffix(1) == ["10.173.11.15"])
    }

    @Test
    func parsesCombinedUsernameOnlyWhenHostIsEmpty() throws {
        let profile = SSHProfile(name: "Combined endpoint", host: "", username: "hwjeong@sysadmin@10.171.30.22")
        let command = try SSHCommandBuilder().build(for: profile)
        #expect(optionValue(after: "-l", in: command.arguments) == "hwjeong@sysadmin")
        #expect(command.arguments.suffix(1) == ["10.171.30.22"])
    }

    @Test
    func directAgentConnectionUsesSecureArgumentArray() throws {
        let profile = SSHProfile(
            name: "Production",
            host: "server.example.com",
            port: 2222,
            username: "deploy",
            authentication: .agent(socketPath: "/tmp/bitwarden agent.sock")
        )
        let command = try SSHCommandBuilder().build(for: profile)
        #expect(command.arguments.contains("-tt"))
        #expect(command.arguments.contains("IdentityAgent=SSH_AUTH_SOCK"))
        #expect(!command.arguments.contains(where: { $0.contains("/tmp/bitwarden agent.sock") }))
        #expect(command.environmentOverrides["SSH_AUTH_SOCK"] == "/tmp/bitwarden agent.sock")
        #expect(!command.arguments.contains(where: { $0.contains("sh -c") }))
    }

    @Test
    func recursiveJumpProfilesPreserveOuterToInnerOrder() throws {
        let relay = SSHProfile(id: UUID(), name: "Relay", host: "relay.example.com", username: "relay")
        let bastion = SSHProfile(id: UUID(), name: "Bastion", host: "bastion.example.com", username: "jump", jumpHostProfileIDs: [relay.id])
        let target = SSHProfile(id: UUID(), name: "Private", host: "db.internal", username: "app", jumpHostProfileIDs: [bastion.id])
        let route = try SSHRouteResolver.resolve(target: target, profiles: [relay, bastion, target])
        #expect(route.hops.map(\.id) == [relay.id, bastion.id])

        let configuration = try SSHRouteConfiguration(route: route)
        defer { try? FileManager.default.removeItem(at: configuration.directoryURL) }
        let command = try SSHCommandBuilder().build(route: route, configuration: configuration)
        #expect(command.arguments.contains("-F"))
        #expect(command.arguments.last == configuration.targetAlias)
        let text = String(decoding: try Data(contentsOf: configuration.fileURL), as: UTF8.self)
        #expect(text.contains("ProxyJump osxterm-" + relay.id.uuidString.lowercased()))
        #expect(!text.contains("secret"))
    }

    @Test
    func rejectsCyclesAndMissingReferences() {
        let a = UUID()
        let b = UUID()
        let first = SSHProfile(id: a, name: "A", host: "a.example.com", username: "a", jumpHostProfileIDs: [b])
        let second = SSHProfile(id: b, name: "B", host: "b.example.com", username: "b", jumpHostProfileIDs: [a])
        #expect(throws: SSHRouteError.cyclicReference([a, b, a])) {
            try SSHRouteResolver.resolve(target: first, profiles: [first, second])
        }

        let missing = SSHProfile(name: "Missing", host: "target.example.com", username: "user", jumpHostProfileIDs: [UUID()])
        #expect(throws: SSHRouteError.missingProfile(missing.jumpHostProfileIDs[0])) {
            try SSHRouteResolver.resolve(target: missing, profiles: [missing])
        }
    }

    @Test
    func currentProfilesDoNotPersistOrEmitForwarding() throws {
        let profile = SSHProfile(name: "No forwarding", host: "server.example.com", username: "user")
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(!encoded.contains("forwards"))
        let command = try SSHCommandBuilder().build(for: profile)
        #expect(!command.arguments.contains("-L"))
        #expect(!command.arguments.contains("-R"))
        #expect(!command.arguments.contains("-D"))
    }

    @Test
    func passwordProfileRequiresSessionAskPassWithoutPersistedReference() throws {
        let profile = SSHProfile(name: "Password", host: "server.example.com", username: "user", authentication: .password)
        let command = try SSHCommandBuilder().build(for: profile)
        #expect(command.requiresAskPass)
        #expect(command.arguments.contains("NumberOfPasswordPrompts=1"))
    }

    @Test
    func sessionAskPassPromptSelectsMatchingCredential() throws {
        let server = try SessionAskPassServer(credentials: [
            "jump@bastion.example.com": "jump-password",
            "deploy@server.example.com": "target-password"
        ])
        defer { server.stop() }
        let response = try SessionAskPassClient.readCredential(
            socketPath: server.socketPath,
            prompt: "deploy@server.example.com's password:"
        )
        #expect(response == Data("target-password\n".utf8))
    }

    private func optionValue(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
