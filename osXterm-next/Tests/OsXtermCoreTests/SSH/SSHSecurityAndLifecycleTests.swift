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
    func tunnelParserFindsRemotePortAllocationAndReconnectPolicySkipsAuthFailures() async throws {
        let rule = ForwardingRule(name: "dynamic", kind: .remoteDynamic, listenPort: 0)
        let lifecycle = TunnelLifecycle(rules: [rule])
        try await lifecycle.begin()
        await lifecycle.consumeOpenSSHStandardError("Allocated port 49211 for remote forward to socks:0\n")
        let snapshot = try await lifecycle.snapshot(for: rule.id)
        #expect(snapshot.status == .listening(assignedPort: 49211))

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
