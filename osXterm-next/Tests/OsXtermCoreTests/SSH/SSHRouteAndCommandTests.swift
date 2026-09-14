import Foundation
import Testing
@testable import OsXtermCore

struct SSHRouteAndCommandTests {
    @Test
    func resolvesNestedJumpProfilesFromOuterToInner() throws {
        let outer = ConnectionProfile(name: "outer", host: "outer.example", username: "outer")
        let inner = ConnectionProfile(
            name: "inner",
            host: "inner.example",
            username: "inner",
            jumpProfileIDs: [outer.id]
        )
        let target = ConnectionProfile(
            name: "target",
            host: "target.internal",
            username: "app",
            jumpProfileIDs: [inner.id]
        )

        let route = try SSHRouteResolver.resolve(target: target, profiles: [outer, inner, target])

        #expect(route.hops.map(\.id) == [outer.id, inner.id])
        #expect(route.target.id == target.id)
    }

    @Test
    func rejectsCyclesMissingProfilesAndInnerProxies() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = ConnectionProfile(
            id: firstID,
            name: "first",
            host: "first.example",
            username: "ops",
            jumpProfileIDs: [secondID]
        )
        let second = ConnectionProfile(
            id: secondID,
            name: "second",
            host: "second.example",
            username: "ops",
            jumpProfileIDs: [firstID]
        )
        #expect(throws: SSHRouteError.self) {
            try SSHRouteResolver.resolve(target: first, profiles: [first, second])
        }

        let missing = ConnectionProfile(
            name: "missing",
            host: "target.example",
            username: "ops",
            jumpProfileIDs: [UUID()]
        )
        #expect(throws: SSHRouteError.self) {
            try SSHRouteResolver.resolve(target: missing, profiles: [missing])
        }

        let outer = ConnectionProfile(name: "outer", host: "outer.example", username: "ops")
        let innerWithProxy = ConnectionProfile(
            name: "inner",
            host: "inner.example",
            username: "ops",
            jumpProfileIDs: [outer.id],
            proxy: ProxyConfiguration(kind: .socks5, host: "proxy.example", port: 1080)
        )
        let target = ConnectionProfile(
            name: "target",
            host: "target.example",
            username: "ops",
            jumpProfileIDs: [innerWithProxy.id]
        )
        #expect(throws: SSHRouteError.self) {
            try SSHRouteResolver.resolve(target: target, profiles: [outer, innerWithProxy, target])
        }
    }

    @Test
    func emitsGeneratedConfigAndSafeProxyHelperArguments() throws {
        let secret = SecretReference()
        let outer = ConnectionProfile(name: "jump", host: "jump.example", username: "jump")
        let target = ConnectionProfile(
            name: "target",
            host: "db.internal",
            port: 2222,
            username: "deploy@realm",
            authentication: .password(secret: secret),
            jumpProfileIDs: [outer.id],
            proxy: ProxyConfiguration(
                kind: .httpConnect,
                host: "proxy.example",
                port: 8080,
                username: "build",
                password: secret
            )
        )
        let route = try SSHRouteResolver.resolve(target: target, profiles: [outer, target])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let knownHostsURL = directory.appendingPathComponent("known_hosts")
        let proxy = ProxyHelperLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/private/tmp/osXtermProxy"),
            socketPath: "/private/tmp/proxy-broker.sock",
            token: "unit-test-token"
        )

        let prepared = try OpenSSHCommandCompiler().prepare(
            route: route,
            knownHostsURL: knownHostsURL,
            proxyHelper: proxy,
            baseDirectory: directory
        )
        defer { prepared.configuration.cleanup() }
        let config = try String(contentsOf: prepared.configuration.fileURL, encoding: .utf8)

        #expect(prepared.invocation.executableURL.path == "/usr/bin/ssh")
        #expect(prepared.invocation.arguments.contains("-F"))
        #expect(prepared.invocation.arguments.last == prepared.configuration.targetAlias)
        #expect(config.contains("ProxyJump \"osxterm-\(outer.id.uuidString.lowercased())\""))
        #expect(config.contains("--kind' 'http-connect' '--host' 'proxy.example' '--port' '8080'"))
        #expect(config.contains("'--target-host' '%h' '--target-port' '%p'"))
        #expect(config.contains("'--credential-socket' '/private/tmp/proxy-broker.sock' '--credential-token' 'unit-test-token' '--username' 'build'"))
        #expect(!config.contains("secret-"))
        #expect(config.contains("PreferredAuthentications keyboard-interactive,password"))
        #expect(!config.contains(secret.keychainAccount))
        #expect(prepared.invocation.requiresAskPass)
        let outerAlias = OpenSSHRouteConfiguration.alias(for: outer)
        let targetAlias = OpenSSHRouteConfiguration.alias(for: target)
        let blocks = config.components(separatedBy: "\n\n")
        let outerBlock = blocks.first { $0.contains("Host \(outerAlias)") } ?? ""
        let targetBlock = blocks.first { $0.contains("Host \(targetAlias)") } ?? ""
        #expect(outerBlock.contains("ProxyCommand "))
        #expect(!targetBlock.contains("ProxyCommand "))
        #expect(targetBlock.contains("ProxyJump \"\(outerAlias)\""))
        #expect(prepared.invocation.credentialRequirements.contains(.proxy(
            secret: secret,
            prompt: "proxy:build@proxy.example:8080"
        )))
    }

    @Test
    func compilesAllSupportedForwardingKindsWithoutShellArguments() throws {
        let rules = [
            ForwardingRule(name: "local", kind: .local, listenPort: 15432, destinationHost: "db.internal", destinationPort: 5432),
            ForwardingRule(name: "remote", kind: .remote, listenPort: 0, destinationHost: "127.0.0.1", destinationPort: 8080),
            ForwardingRule(name: "socks", kind: .dynamic, listenPort: 1080),
            ForwardingRule(name: "remote socks", kind: .remoteDynamic, listenPort: 0),
            ForwardingRule(name: "local unix", kind: .localUnix, listenPath: "/tmp/local.sock", destinationPath: "/tmp/remote.sock"),
            ForwardingRule(name: "remote unix", kind: .remoteUnix, listenPath: "/tmp/remote-listen.sock", destinationHost: "localhost", destinationPort: 9000)
        ]
        let target = ConnectionProfile(
            name: "target",
            host: "target.example",
            username: "ops",
            forwardingRules: rules
        )
        let route = try SSHRouteResolver.resolve(target: target, profiles: [target])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try OpenSSHRouteConfiguration(
            route: route,
            knownHostsURL: directory.appendingPathComponent("known_hosts"),
            baseDirectory: directory
        )
        defer { configuration.cleanup() }

        let invocation = try OpenSSHCommandCompiler().compile(
            route: route,
            configuration: configuration,
            purpose: .tunnel
        )

        #expect(invocation.arguments.contains("-N"))
        #expect(invocation.arguments.contains("127.0.0.1:15432:db.internal:5432"))
        #expect(invocation.arguments.contains("127.0.0.1:0:127.0.0.1:8080"))
        #expect(invocation.arguments.contains("127.0.0.1:1080"))
        #expect(invocation.arguments.contains("127.0.0.1:0"))
        #expect(invocation.arguments.contains("/tmp/local.sock:/tmp/remote.sock"))
        #expect(invocation.arguments.contains("/tmp/remote-listen.sock:localhost:9000"))
        #expect(!invocation.arguments.contains(where: { $0.contains("sh -c") }))
    }

    @Test
    func preparesSCPWithTheSameRouteConfigurationAndNoRemoteShellArgument() throws {
        let jump = ConnectionProfile(name: "jump", host: "jump.example", username: "ops")
        let target = ConnectionProfile(
            name: "target",
            host: "target.example",
            username: "deploy",
            jumpProfileIDs: [jump.id]
        )
        let route = try SSHRouteResolver.resolve(target: target, profiles: [jump, target])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let prepared = try OpenSSHCommandCompiler().prepareSCP(
            route: route,
            knownHostsURL: directory.appendingPathComponent("known_hosts"),
            baseDirectory: directory
        )
        defer { prepared.configuration.cleanup() }

        #expect(prepared.invocation.executableURL.path == "/usr/bin/scp")
        #expect(prepared.invocation.purpose == .fileTransfer)
        #expect(prepared.invocation.arguments == [
            "-F", prepared.configuration.fileURL.path,
            "-o", "BatchMode=no",
            "-o", "LogLevel=VERBOSE"
        ])
        let config = try String(contentsOf: prepared.configuration.fileURL, encoding: .utf8)
        #expect(config.contains("ProxyJump \"osxterm-\(jump.id.uuidString.lowercased())\""))
    }

    @Test
    func rejectsUnsafeHostsAndUnapprovedExternalForwarding() throws {
        let unsafe = ConnectionProfile(name: "unsafe", host: "host\nProxyCommand evil", username: "ops")
        let route = ResolvedSSHRoute(hops: [], target: unsafe)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: OpenSSHCommandCompilerError.self) {
            try OpenSSHRouteConfiguration(
                route: route,
                knownHostsURL: directory.appendingPathComponent("known_hosts"),
                baseDirectory: directory
            )
        }

        let rule = ForwardingRule(
            name: "public",
            kind: .local,
            bindAddress: "0.0.0.0",
            listenPort: 8080,
            destinationHost: "localhost",
            destinationPort: 80,
            exposeExternally: false
        )
        let profile = ConnectionProfile(name: "target", host: "target.example", username: "ops", forwardingRules: [rule])
        let validRoute = ResolvedSSHRoute(hops: [], target: profile)
        let configuration = try OpenSSHRouteConfiguration(
            route: validRoute,
            knownHostsURL: directory.appendingPathComponent("valid-known_hosts"),
            baseDirectory: directory
        )
        defer { configuration.cleanup() }
        #expect(throws: OpenSSHCommandCompilerError.self) {
            try OpenSSHCommandCompiler().compile(route: validRoute, configuration: configuration, purpose: .tunnel)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
