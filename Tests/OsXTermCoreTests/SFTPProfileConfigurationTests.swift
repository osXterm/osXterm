import Foundation
import Testing
@testable import OsXTermCore

@Suite
struct SFTPProfileConfigurationTests {
    @Test
    func parsesCombinedUsernameTargetForSFTP() throws {
        let profile = SSHProfile(
            name: "Realm endpoint",
            host: "10.173.11.15",
            username: "hwjeong@sysadmin@10.171.30.22"
        )

        let configuration = try SFTPConnectionConfiguration(profile: profile)

        #expect(configuration.host == "10.173.11.15")
        #expect(configuration.username == "hwjeong@sysadmin@10.171.30.22")
    }

    @Test
    func parsesCombinedUsernameWhenHostIsEmpty() throws {
        let profile = SSHProfile(
            name: "Combined endpoint",
            host: "",
            username: "hwjeong@sysadmin@10.171.30.22"
        )

        let configuration = try SFTPConnectionConfiguration(profile: profile)

        #expect(configuration.host == "10.171.30.22")
        #expect(configuration.username == "hwjeong@sysadmin")
    }

    @Test
    func testPasswordProfileConfiguresSessionAskPassAndDisablesOpenSSHBatchAuthentication() throws {
        let profile = SSHProfile(
            name: "Password host",
            host: "server.example.com",
            port: 2022,
            username: "deploy",
            authentication: .password,
            jumpHosts: [
                SSHJumpHost(
                    host: "jump.example.com",
                    port: 2200,
                    username: "jumper"
                )
            ]
        )

        let configuration = try SFTPConnectionConfiguration(
            profile: profile,
            askPassPath: "/Applications/osXterm.app/Contents/MacOS/osXtermAskPass",
            askPassSocketPath: "/private/tmp/osxterm-test-askpass.sock"
        )

        #expect(configuration.host == "server.example.com")
        #expect(configuration.port == 2022)
        #expect(
            configuration.jumpHosts == [
                SFTPJumpHost(
                    host: "jump.example.com",
                    port: 2200,
                    username: "jumper"
                )
            ]
        )
        #expect(
            configuration.environment["SSH_ASKPASS"]
                == "/Applications/osXterm.app/Contents/MacOS/osXtermAskPass"
        )
        #expect(configuration.environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(configuration.environment["DISPLAY"] == "osXterm")
        #expect(
            configuration.environment["OSXTERM_ASKPASS_SOCKET"]
                == "/private/tmp/osxterm-test-askpass.sock"
        )
        #expect(!configuration.usesOpenSSHBatchMode)
    }

    @Test
    func testAgentProfileMapsSocketAndKeepsBatchMode() throws {
        let profile = SSHProfile(
            name: "Agent host",
            host: "server.example.com",
            username: "deploy",
            authentication: .agent(socketPath: "/tmp/bitwarden-agent.sock")
        )

        let configuration = try SFTPConnectionConfiguration(profile: profile)

        #expect(configuration.sshAgentSocketPath == "/tmp/bitwarden-agent.sock")
        #expect(configuration.usesOpenSSHBatchMode)
        #expect(configuration.environment.isEmpty)
    }

    @Test
    func testPasswordProfileRequiresAskPassHelper() {
        let profile = SSHProfile(
            name: "Password host",
            host: "server.example.com",
            username: "deploy",
            authentication: .password
        )

        do {
            _ = try SFTPConnectionConfiguration(profile: profile)
            Issue.record("Expected invalid configuration error")
        } catch let error as SFTPError {
            guard case .invalidConfiguration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
