import Foundation
import Testing
@testable import OsXtermCore

struct OpenSSHRuntimeSupportTests {
    @Test
    func parsesVersionAndRejectsUnsupportedFeatureSets() throws {
        #expect(try OpenSSHVersion(parsing: "OpenSSH_10.3p1, LibreSSL 3.3.6") == OpenSSHVersion(major: 10, minor: 3, patch: 1))
        #expect(throws: OpenSSHRuntimeSupportError.self) {
            try OpenSSHVersion(parsing: "not an OpenSSH banner")
        }

        let jump = ConnectionProfile(name: "jump", host: "jump.example", username: "ops")
        let target = ConnectionProfile(
            name: "target",
            host: "target.example",
            username: "ops",
            jumpProfileIDs: [jump.id]
        )
        let jumpRoute = try SSHRouteResolver.resolve(target: target, profiles: [jump, target])

        #expect(throws: OpenSSHRuntimeSupportError.self) {
            try OpenSSHCapabilities(version: OpenSSHVersion(major: 7, minor: 2))
                .validate(route: jumpRoute, forwardingRules: [])
        }
        #expect(throws: OpenSSHRuntimeSupportError.self) {
            try OpenSSHCapabilities(version: OpenSSHVersion(major: 7, minor: 5))
                .validate(
                    route: ResolvedSSHRoute(hops: [], target: target),
                    forwardingRules: [ForwardingRule(name: "remote socks", kind: .remoteDynamic, listenPort: 0)]
                )
        }
        #expect(throws: OpenSSHRuntimeSupportError.self) {
            try OpenSSHCapabilities(version: OpenSSHVersion(major: 6, minor: 6))
                .validate(
                    route: ResolvedSSHRoute(hops: [], target: target),
                    forwardingRules: [ForwardingRule(name: "socket", kind: .localUnix, listenPath: "/tmp/osxterm.sock", destinationPath: "/tmp/target.sock")]
                )
        }
        #expect(throws: OpenSSHRuntimeSupportError.self) {
            try OpenSSHCapabilities(version: OpenSSHVersion(major: 8, minor: 9))
                .validateSFTPBackedSCP()
        }
    }

    @Test
    func installedOpenSSHSupportsTheAppFeatureBaseline() throws {
        let capabilities = try OpenSSHCapabilities.current()
        let jump = ConnectionProfile(name: "jump", host: "jump.example", username: "ops")
        let target = ConnectionProfile(
            name: "target",
            host: "target.example",
            username: "ops",
            jumpProfileIDs: [jump.id]
        )
        let route = try SSHRouteResolver.resolve(target: target, profiles: [jump, target])
        let forwardingRules = [
            ForwardingRule(name: "remote socks", kind: .remoteDynamic, listenPort: 0),
            ForwardingRule(name: "local socket", kind: .localUnix, listenPath: "/tmp/osxterm-local.sock", destinationPath: "/tmp/osxterm-remote.sock"),
            ForwardingRule(name: "remote socket", kind: .remoteUnix, listenPath: "/tmp/osxterm-listen.sock", destinationHost: "localhost", destinationPort: 8080)
        ]

        try capabilities.validate(route: route, forwardingRules: forwardingRules)
        try capabilities.validateSFTPBackedSCP()
        #expect(capabilities.version >= OpenSSHCapabilities.sftpBackedSCPMinimum)
    }
}
