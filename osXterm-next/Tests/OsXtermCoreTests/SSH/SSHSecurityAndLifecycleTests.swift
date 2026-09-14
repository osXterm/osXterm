import Darwin
import Foundation
import Testing
@testable import OsXtermCore

struct SSHSecurityAndLifecycleTests {
    @Test
    func hostKeyStoreRequiresExplicitChangedKeyReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HostKeyStore(fileURL: directory.appendingPathComponent("known_hosts"))
        let endpoint = try SSHHostKeyEndpoint(host: "db.example", port: 2222)
        let original = try SSHHostKey(algorithm: "ssh-ed25519", base64EncodedKey: "AQIDBA==")
        let replacement = try SSHHostKey(algorithm: "ssh-ed25519", base64EncodedKey: "BQYHCA==")

        #expect(await store.verification(endpoint: endpoint, presented: original) == .unknown(presentedFingerprint: original.sha256Fingerprint))
        try await store.approve(endpoint: endpoint, presented: original, approval: .trustNew)
        #expect(await store.verification(endpoint: endpoint, presented: original) == .trusted(fingerprint: original.sha256Fingerprint))
        var rejectedChangedKey = false
        do {
            try await store.approve(endpoint: endpoint, presented: replacement, approval: .trustNew)
        } catch is HostKeyStoreError {
            rejectedChangedKey = true
        }
        #expect(rejectedChangedKey)
        try await store.approve(endpoint: endpoint, presented: replacement, approval: .replaceChanged)
        #expect(await store.verification(endpoint: endpoint, presented: replacement) == .trusted(fingerprint: replacement.sha256Fingerprint))
        let text = try String(contentsOf: directory.appendingPathComponent("known_hosts"), encoding: .utf8)
        #expect(text.contains("[db.example]:2222 ssh-ed25519 BQYHCA=="))
        #expect(!text.contains("AQIDBA=="))
    }

    @Test
    func generatedConfigRequiresKnownKeysUntilUserConfirmationPolicyIsChosen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ConnectionProfile(name: "target", host: "target.example", username: "ops")
        let route = ResolvedSSHRoute(hops: [], target: profile)
        let strict = try OpenSSHRouteConfiguration(
            route: route,
            knownHostsURL: directory.appendingPathComponent("known_hosts"),
            baseDirectory: directory
        )
        defer { strict.cleanup() }
        let confirmed = try OpenSSHRouteConfiguration(
            route: route,
            knownHostsURL: directory.appendingPathComponent("known_hosts"),
            hostKeyPolicy: .acceptNewAfterUserConfirmation,
            baseDirectory: directory
        )
        defer { confirmed.cleanup() }

        #expect(try String(contentsOf: strict.fileURL, encoding: .utf8).contains("StrictHostKeyChecking yes"))
        #expect(try String(contentsOf: confirmed.fileURL, encoding: .utf8).contains("StrictHostKeyChecking accept-new"))
    }

    @Test
    func brokerReturnsOnlyTokenAuthorizedPromptResponse() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = try SessionCredentialBroker(
            responses: [
                "deploy@db.example": "target-password",
                "default": "fallback"
            ],
            baseDirectory: directory
        )
        defer { broker.stop() }

        let value = try AskPassClient.requestResponse(
            socketPath: broker.socketPath,
            token: broker.token,
            prompt: "deploy@db.example's password:"
        )
        #expect(value == "target-password")
        #expect(throws: CredentialBrokerError.self) {
            try AskPassClient.requestResponse(
                socketPath: broker.socketPath,
                token: "wrong-token",
                prompt: "deploy@db.example's password:"
            )
        }
    }

    @Test
    func proxyInvocationUsesThePackagedHelperContract() throws {
        let invocation = try ProxyHelperInvocation(
            kind: .socks5,
            proxyHost: "proxy.example",
            proxyPort: 1080,
            targetHost: "db.internal",
            targetPort: 22,
            credentialSocketPath: "/private/tmp/proxy.sock",
            credentialToken: "token",
            username: "alice"
        )
        let arguments = try invocation.argumentVector(executableURL: URL(fileURLWithPath: "/Applications/osXterm.app/Contents/MacOS/osXtermProxy"))
        #expect(arguments == [
            "/Applications/osXterm.app/Contents/MacOS/osXtermProxy",
            "--kind", "socks5",
            "--host", "proxy.example",
            "--port", "1080",
            "--target-host", "db.internal",
            "--target-port", "22",
            "--credential-socket", "/private/tmp/proxy.sock",
            "--credential-token", "token",
            "--username", "alice"
        ])
        let parsed = try ProxyHelperInvocation.parse(arguments: Array(arguments.dropFirst()))
        #expect(parsed == invocation)
        #expect(ProxyCredentialPrompt.make(username: "Alice", host: "proxy.example", port: 1080) == "proxy:alice@proxy.example:1080")
    }

    @Test
    func tunnelKeepsListenerStateWhenDestinationProbeFails() async throws {
        let rule = ForwardingRule(name: "database", kind: .remote, listenPort: 0, destinationHost: "localhost", destinationPort: 5432)
        let lifecycle = TunnelLifecycle(rules: [rule])

        try await lifecycle.begin()
        try await lifecycle.confirmListener(ruleID: rule.id, assignedPort: 49211)
        try await lifecycle.beginProbe(ruleID: rule.id)
        try await lifecycle.completeProbe(ruleID: rule.id, reachable: false, errorMessage: "Connection refused")

        let snapshot = try await lifecycle.snapshot(for: rule.id)
        #expect(snapshot.status == .listening(assignedPort: 49211))
        #expect(snapshot.destination == .unreachable(message: "Connection refused"))
        #expect(snapshot.assignedPort == 49211)
    }

    @Test
    func destinationProbeUsesTheActualLocalListenerOrLocalDestination() async {
        let local = ForwardingRule(
            name: "local",
            kind: .local,
            bindAddress: "0.0.0.0",
            listenPort: 15432,
            destinationHost: "db.internal",
            destinationPort: 5432,
            exposeExternally: true
        )
        let localSocket = ForwardingRule(
            name: "local socket",
            kind: .localUnix,
            listenPath: "/private/tmp/osxterm-listener.sock",
            destinationPath: "/private/tmp/osxterm-target.sock"
        )
        let remote = ForwardingRule(
            name: "remote",
            kind: .remote,
            listenPort: 0,
            destinationHost: "127.0.0.1",
            destinationPort: 8080
        )
        let dynamic = ForwardingRule(name: "dynamic", kind: .dynamic, listenPort: 1080)

        #expect(TunnelDestinationProbe.target(for: local) == .tcp(host: "127.0.0.1", port: 15432))
        #expect(TunnelDestinationProbe.target(for: localSocket) == .unix(path: "/private/tmp/osxterm-listener.sock"))
        #expect(TunnelDestinationProbe.target(for: remote, assignedPort: 49211) == .tcp(host: "127.0.0.1", port: 8080))
        #expect(TunnelDestinationProbe.target(for: dynamic) == nil)
        #expect(await TunnelDestinationProbe.probe(.tcp(host: "invalid host", port: 0)) == .unreachable(.invalidEndpoint))
    }

    @Test
    func destinationProbeConnectsToALiveLocalTCPListener() async throws {
        let listener = try TCPProbeListener()

        let result = await TunnelDestinationProbe.probe(
            .tcp(host: "127.0.0.1", port: listener.port),
            timeoutMilliseconds: 1_000
        )
        withExtendedLifetime(listener) {}

        #expect(result == .reachable)
    }

    @Test
    func destinationProbeConnectsToALiveLocalUnixListener() async throws {
        let path = "/private/tmp/osxterm-probe-\(UUID().uuidString.lowercased().prefix(12)).sock"
        let listener = try UnixProbeListener(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = await TunnelDestinationProbe.probe(
            .unix(path: path),
            timeoutMilliseconds: 1_000
        )
        withExtendedLifetime(listener) {}

        #expect(result == .reachable)
    }

    @Test
    func tunnelParserFindsRemotePortAllocationAndReconnectPolicySkipsAuthFailures() async throws {
        let rule = ForwardingRule(name: "dynamic", kind: .remoteDynamic, listenPort: 0)
        let lifecycle = TunnelLifecycle(rules: [rule])
        #expect(try await lifecycle.snapshot(for: rule.id).destination == .notApplicable)
        try await lifecycle.begin()
        await lifecycle.consumeOpenSSHStandardError("Allocated port 49211 for remote forward to socks:0\n")
        let snapshot = try await lifecycle.snapshot(for: rule.id)
        #expect(snapshot.status == .listening(assignedPort: 49211))
        #expect(snapshot.destination == .notApplicable)

        let options = SSHOptions(autoReconnect: true, maximumReconnectAttempts: 3)
        #expect(SSHReconnectPolicy.nextPlan(after: .authentication, completedAttempts: 0, options: options) == nil)
        #expect(SSHReconnectPolicy.nextPlan(after: .transport(message: "reset"), completedAttempts: 0, options: options) == SSHReconnectPlan(attempt: 1, delay: 1))
        #expect(SSHReconnectPolicy.nextPlan(after: .transport(message: "reset"), completedAttempts: 3, options: options) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private final class TCPProbeListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        self.descriptor = descriptor

        var reuseAddress: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: Darwin.inet_addr("127.0.0.1"))
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didReadAddress = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard didReadAddress == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    deinit { Darwin.close(descriptor) }
}

private final class UnixProbeListener {
    let descriptor: Int32
    let path: String

    init(path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        self.descriptor = descriptor
        self.path = path

        var address = try SessionCredentialBroker.socketAddress(path: path)
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard didBind == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
    }

    deinit {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(atPath: path)
    }
}
