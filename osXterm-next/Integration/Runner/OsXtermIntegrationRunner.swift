import CryptoKit
import Foundation
import OsXtermCore

enum IntegrationRunnerError: LocalizedError {
    case missingEnvironment(String)
    case invocationFailed(String)
    case assertionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingEnvironment(name): "Missing integration environment value: \(name)"
        case let .invocationFailed(message), let .assertionFailed(message): message
        }
    }
}

@main
struct OsXtermIntegrationRunner {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().elementsEqual(["--verify-process-capture"]) {
                try verifyProcessCapture()
                print("Process capture smoke passed; SSH integration was not run.")
                return
            }
            try await run()
            print("osXterm integration runner completed.")
        } catch {
            fputs("osXterm integration runner failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func verifyProcessCapture() throws {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 262144 /dev/zero; /usr/bin/head -c 262144 /dev/zero >&2"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        guard result.status == 0, result.output.utf8.count == 262_144, result.error.utf8.count == 262_144 else {
            throw IntegrationRunnerError.assertionFailed("Large stdout and stderr capture was incomplete.")
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureDirectory = try required("OSXTERM_FIXTURE_DIRECTORY", environment)
        let privateKey = URL(fileURLWithPath: fixtureDirectory).appendingPathComponent("id_ed25519")
        let encryptedPrivateKey = URL(fileURLWithPath: fixtureDirectory).appendingPathComponent("id_ed25519_encrypted")
        let certificate = URL(fileURLWithPath: fixtureDirectory).appendingPathComponent("id_ed25519-cert.pub")
        let knownHosts = URL(fileURLWithPath: fixtureDirectory).appendingPathComponent("known_hosts")
        let proxyHelper = URL(fileURLWithPath: try required("OSXTERM_PROXY_HELPER", environment))
        let askPassHelper = URL(fileURLWithPath: try required("OSXTERM_ASKPASS_HELPER", environment))
        let ssh1Port = try port("OSXTERM_SSH1_PORT", environment)
        let targetPort = try port("OSXTERM_TARGET_PORT", environment)
        let restrictedTargetPort = try port("OSXTERM_RESTRICTED_TARGET_PORT", environment)
        let certificateTargetPort = try port("OSXTERM_CERT_TARGET_PORT", environment)
        let httpProxyPort = try port("OSXTERM_HTTP_PROXY_PORT", environment)
        let socksProxyPort = try port("OSXTERM_SOCKS_PROXY_PORT", environment)
        let httpAuthenticatedProxyPort = try port("OSXTERM_HTTP_AUTH_PROXY_PORT", environment)
        let socksAuthenticatedProxyPort = try port("OSXTERM_SOCKS_AUTH_PROXY_PORT", environment)
        let echoPort = try port("OSXTERM_ECHO_PORT", environment)

        try FileManager.default.createDirectory(at: URL(fileURLWithPath: fixtureDirectory), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: knownHosts.path) {
            try Data().write(to: knownHosts, options: .atomic)
        }

        let direct = profile(
            name: "direct",
            host: "127.0.0.1",
            port: targetPort,
            key: privateKey.path
        )
        let jump1 = profile(name: "jump1", host: "127.0.0.1", port: ssh1Port, key: privateKey.path)
        // The second jump is resolved from ssh1's Docker network namespace.
        // Using the host loopback address here would send ssh1 back to itself
        // instead of to the ssh2 fixture service.
        let jump2 = profile(name: "jump2", host: "ssh2", port: 2222, key: privateKey.path)
        var target = profile(name: "target", host: "target", port: 2222, key: privateKey.path)
        target.jumpProfileIDs = [jump1.id, jump2.id]

        try await assertSession(
            target: direct,
            profiles: [direct],
            knownHosts: knownHosts,
            proxyHelper: nil,
            label: "direct"
        )
        var oneHopTarget = profile(name: "one-hop-target", host: "target", port: 2222, key: privateKey.path)
        oneHopTarget.jumpProfileIDs = [jump1.id]
        try await assertSession(
            target: oneHopTarget,
            profiles: [jump1, oneHopTarget],
            knownHosts: knownHosts,
            proxyHelper: nil,
            label: "one-hop jump"
        )
        try await assertCredentialMethods(
            targetPort: targetPort,
            certificateTargetPort: certificateTargetPort,
            privateKey: privateKey,
            encryptedPrivateKey: encryptedPrivateKey,
            certificate: certificate,
            knownHosts: knownHosts,
            askPassHelper: askPassHelper
        )
        try await assertSession(
            target: target,
            profiles: [jump1, jump2, target],
            knownHosts: knownHosts,
            proxyHelper: nil,
            label: "two-hop jump"
        )
        try await assertHopAuthenticationFailures(
            ssh1Port: ssh1Port,
            privateKey: privateKey,
            askPassHelper: askPassHelper
        )
        try await assertChangedHostKeyIsRejected(
            targetPort: targetPort,
            privateKey: privateKey
        )

        let proxyReachableTarget = profile(name: "proxy-target", host: "target", port: 2222, key: privateKey.path)
        var httpTarget = proxyReachableTarget
        httpTarget.name = "http-proxy"
        httpTarget.proxy = ProxyConfiguration(kind: .httpConnect, host: "127.0.0.1", port: httpProxyPort)
        try await assertSession(
            target: httpTarget,
            profiles: [httpTarget],
            knownHosts: knownHosts,
            proxyHelper: ProxyHelperLaunchConfiguration(executableURL: proxyHelper, sessionID: UUID()),
            label: "HTTP CONNECT proxy"
        )

        var socksTarget = proxyReachableTarget
        socksTarget.id = UUID()
        socksTarget.name = "socks-proxy"
        socksTarget.proxy = ProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: socksProxyPort)
        try await assertSession(
            target: socksTarget,
            profiles: [socksTarget],
            knownHosts: knownHosts,
            proxyHelper: ProxyHelperLaunchConfiguration(executableURL: proxyHelper, sessionID: UUID()),
            label: "SOCKS5 proxy"
        )

        let proxyJump1 = profile(name: "proxy-jump1", host: "ssh1", port: 2222, key: privateKey.path)
        let proxyJump2 = profile(name: "proxy-jump2", host: "ssh2", port: 2222, key: privateKey.path)
        var proxiedJumpTarget = profile(name: "proxy-jump-target", host: "target", port: 2222, key: privateKey.path)
        proxiedJumpTarget.jumpProfileIDs = [proxyJump1.id, proxyJump2.id]
        proxiedJumpTarget.name = "proxy-jump"
        proxiedJumpTarget.proxy = ProxyConfiguration(kind: .httpConnect, host: "127.0.0.1", port: httpProxyPort)
        try await assertSession(
            target: proxiedJumpTarget,
            profiles: [proxyJump1, proxyJump2, proxiedJumpTarget],
            knownHosts: knownHosts,
            proxyHelper: ProxyHelperLaunchConfiguration(executableURL: proxyHelper, sessionID: UUID()),
            label: "HTTP CONNECT plus two-hop jump"
        )

        try await assertAuthenticatedProxySessions(
            target: proxyReachableTarget,
            knownHosts: knownHosts,
            proxyHelper: proxyHelper,
            httpPort: httpAuthenticatedProxyPort,
            socksPort: socksAuthenticatedProxyPort
        )

        try await assertSFTPTransfer(
            target: direct,
            knownHosts: knownHosts,
            fixtureDirectory: URL(fileURLWithPath: fixtureDirectory)
        )
        try assertSCPTransfer(
            target: direct,
            knownHosts: knownHosts,
            fixtureDirectory: URL(fileURLWithPath: fixtureDirectory)
        )
        try await assertTunnelForwarding(
            target: direct,
            restrictedTargetPort: restrictedTargetPort,
            knownHosts: knownHosts,
            echoPort: echoPort
        )
    }

    private static func profile(name: String, host: String, port: Int, key: String) -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            host: host,
            port: port,
            username: "osxterm",
            authentication: .privateKey(path: key, passphrase: nil),
            options: SSHOptions(connectTimeout: 10, serverAliveInterval: 2, serverAliveCountMax: 2)
        )
    }

    private static func assertSession(
        target: ConnectionProfile,
        profiles: [ConnectionProfile],
        knownHosts: URL,
        proxyHelper: ProxyHelperLaunchConfiguration?,
        label: String,
        environment: [String: String]? = nil,
        command: String = "printf osxterm-integration-ok",
        expectedOutput: String = "osxterm-integration-ok"
    ) async throws {
        let result = try compiledSessionResult(
            target: target,
            profiles: profiles,
            knownHosts: knownHosts,
            proxyHelper: proxyHelper,
            hostKeyPolicy: .acceptNewAfterUserConfirmation,
            environment: environment,
            command: command
        )
        guard result.status == 0, result.output.contains(expectedOutput) else {
            throw IntegrationRunnerError.invocationFailed("\(label) did not establish the app-compiled SSH route: \(result.error)")
        }
    }

    private static func compiledSessionResult(
        target: ConnectionProfile,
        profiles: [ConnectionProfile],
        knownHosts: URL,
        proxyHelper: ProxyHelperLaunchConfiguration?,
        hostKeyPolicy: OpenSSHHostKeyPolicy,
        environment: [String: String]? = nil,
        command: String = "printf osxterm-integration-ok"
    ) throws -> (status: Int32, output: String, error: String) {
        let route = try SSHRouteResolver.resolve(target: target, profiles: profiles)
        let prepared = try OpenSSHCommandCompiler().prepare(
            route: route,
            knownHostsURL: knownHosts,
            proxyHelper: proxyHelper,
            hostKeyPolicy: hostKeyPolicy,
            purpose: .interactive,
            baseDirectory: FileManager.default.temporaryDirectory
        )
        defer { prepared.configuration.cleanup() }
        var arguments = prepared.invocation.arguments
        arguments.append(command)
        let result = try runProcess(
            executable: prepared.invocation.executableURL,
            arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment
        )
        return result
    }

    private static func assertHopAuthenticationFailures(
        ssh1Port: Int,
        privateKey: URL,
        askPassHelper: URL
    ) async throws {
        let directory = try temporaryDirectory(named: "authentication-failures")
        defer { try? FileManager.default.removeItem(at: directory) }

        for failedHop in AuthenticationFailureHop.allCases {
            var outer = profile(
                name: "authentication-failure-outer",
                host: "127.0.0.1",
                port: ssh1Port,
                key: privateKey.path
            )
            var inner = profile(
                name: "authentication-failure-inner",
                host: "ssh2",
                port: 2222,
                key: privateKey.path
            )
            var target = profile(
                name: "authentication-failure-target",
                host: "target",
                port: 2222,
                key: privateKey.path
            )
            target.jumpProfileIDs = [outer.id, inner.id]
            target.options.autoReconnect = true
            target.options.maximumReconnectAttempts = 3

            let expectedHost: String
            switch failedHop {
            case .outerJump:
                outer.authentication = .password(secret: SecretReference())
                expectedHost = outer.host
            case .innerJump:
                inner.authentication = .password(secret: SecretReference())
                expectedHost = inner.host
            case .target:
                target.authentication = .password(secret: SecretReference())
                expectedHost = target.host
            }

            try await assertExpectedAuthenticationFailure(
                target: target,
                profiles: [outer, inner, target],
                knownHosts: directory.appendingPathComponent("\(failedHop.fileName)-known_hosts"),
                askPassHelper: askPassHelper,
                expectedHost: expectedHost,
                label: failedHop.label
            )
        }
    }

    private static func assertExpectedAuthenticationFailure(
        target: ConnectionProfile,
        profiles: [ConnectionProfile],
        knownHosts: URL,
        askPassHelper: URL,
        expectedHost: String,
        label: String
    ) async throws {
        let broker = try SessionCredentialBroker(responses: ["default": "not-the-integration-password"])
        defer { broker.stop() }
        let result = try compiledSessionResult(
            target: target,
            profiles: profiles,
            knownHosts: knownHosts,
            proxyHelper: nil,
            hostKeyPolicy: .acceptNewAfterUserConfirmation,
            environment: askPassEnvironment(askPassHelper: askPassHelper, broker: broker)
        )
        let events = OpenSSHOutputParser.events(in: result.error)
        guard result.status != 0 else {
            throw IntegrationRunnerError.assertionFailed("\(label) unexpectedly authenticated with the intentionally incorrect credential.")
        }
        guard events.contains(.authenticationFailed) else {
            throw IntegrationRunnerError.assertionFailed("\(label) did not report an authentication failure: \(result.error)")
        }
        guard result.error.localizedCaseInsensitiveContains(expectedHost) else {
            throw IntegrationRunnerError.assertionFailed("\(label) did not identify the rejected hop \(expectedHost): \(result.error)")
        }
        guard !events.contains(.hostKeyChanged), !events.contains(.hostKeyRejected) else {
            throw IntegrationRunnerError.assertionFailed("\(label) failed at host-key verification instead of authentication: \(result.error)")
        }

        let lifecycle = SSHSessionLifecycle()
        await lifecycle.startResolvingRoute()
        await lifecycle.waitingForAuthentication()
        let reconnectPlan = await lifecycle.failed(.authentication, options: target.options)
        let finalState = await lifecycle.state()
        guard reconnectPlan == nil,
              finalState == .failed(message: "Authentication failed.")
        else {
            throw IntegrationRunnerError.assertionFailed("\(label) scheduled a reconnect after authentication rejection.")
        }
    }

    private static func assertChangedHostKeyIsRejected(
        targetPort: Int,
        privateKey: URL
    ) async throws {
        let directory = try temporaryDirectory(named: "changed-host-key")
        defer { try? FileManager.default.removeItem(at: directory) }

        let knownHosts = directory.appendingPathComponent("known_hosts")
        let endpoint = try SSHHostKeyEndpoint(host: "127.0.0.1", port: targetPort)
        let previousKey = try generatePreviousHostKey(in: directory)
        let store = try HostKeyStore(fileURL: knownHosts)
        try await store.approve(
            endpoint: endpoint,
            presented: previousKey,
            approval: .trustNew
        )

        var target = profile(
            name: "changed-host-key-target",
            host: "127.0.0.1",
            port: targetPort,
            key: privateKey.path
        )
        target.options.autoReconnect = true
        target.options.maximumReconnectAttempts = 3
        let result = try compiledSessionResult(
            target: target,
            profiles: [target],
            knownHosts: knownHosts,
            proxyHelper: nil,
            hostKeyPolicy: .requireKnown
        )
        let events = OpenSSHOutputParser.events(in: result.error)
        guard result.status != 0 else {
            throw IntegrationRunnerError.assertionFailed("Changed host key fixture unexpectedly connected successfully.")
        }
        guard events.contains(.hostKeyChanged),
              OpenSSHHostKeyDiagnosticParser.reportsChangedKey(in: result.error)
        else {
            throw IntegrationRunnerError.assertionFailed("Docker target did not produce a changed host-key rejection: \(result.error)")
        }
        guard !events.contains(.authenticationFailed) else {
            throw IntegrationRunnerError.assertionFailed("Changed host key fixture reached authentication before rejecting the key: \(result.error)")
        }

        let storedRecords = await store.allRecords()
        guard storedRecords == [SSHKnownHostRecord(endpoint: endpoint, key: previousKey)] else {
            throw IntegrationRunnerError.assertionFailed("Changed host key rejection modified the app-managed known_hosts record.")
        }
        let lifecycle = SSHSessionLifecycle()
        await lifecycle.startResolvingRoute()
        await lifecycle.verifyingHostKey()
        let reconnectPlan = await lifecycle.failed(.hostKey, options: target.options)
        let finalState = await lifecycle.state()
        guard reconnectPlan == nil,
              finalState == .failed(message: "Host key verification failed.")
        else {
            throw IntegrationRunnerError.assertionFailed("Changed host key rejection scheduled an automatic reconnect.")
        }
    }

    private static func generatePreviousHostKey(in directory: URL) throws -> SSHHostKey {
        let privateKeyURL = directory.appendingPathComponent("previous-host-key")
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-q", "-t", "ed25519", "-N", "", "-f", privateKeyURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        guard result.status == 0 else {
            throw IntegrationRunnerError.invocationFailed("Could not generate the previous host key fixture: \(result.error)")
        }
        let publicKeyURL = privateKeyURL.appendingPathExtension("pub")
        let fields = try String(contentsOf: publicKeyURL, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else {
            throw IntegrationRunnerError.assertionFailed("Generated previous host key fixture is malformed.")
        }
        return try SSHHostKey(
            algorithm: String(fields[0]),
            base64EncodedKey: String(fields[1])
        )
    }

    private static func askPassEnvironment(
        askPassHelper: URL,
        broker: SessionCredentialBroker
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askPassHelper.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "osxterm-integration:0"
        environment["OSXTERM_ASKPASS_SOCKET"] = broker.socketPath
        environment["OSXTERM_ASKPASS_TOKEN"] = broker.token
        return environment
    }

    private enum AuthenticationFailureHop: CaseIterable {
        case outerJump
        case innerJump
        case target

        var label: String {
            switch self {
            case .outerJump: "outer jump authentication failure"
            case .innerJump: "inner jump authentication failure"
            case .target: "target authentication failure"
            }
        }

        var fileName: String {
            switch self {
            case .outerJump: "outer-jump"
            case .innerJump: "inner-jump"
            case .target: "target"
            }
        }
    }

    private static func assertCredentialMethods(
        targetPort: Int,
        certificateTargetPort: Int,
        privateKey: URL,
        encryptedPrivateKey: URL,
        certificate: URL,
        knownHosts: URL,
        askPassHelper: URL
    ) async throws {
        var password = ConnectionProfile(
            name: "password",
            host: "127.0.0.1",
            port: targetPort,
            username: "osxterm",
            authentication: .password(secret: SecretReference())
        )
        password.options = SSHOptions(connectTimeout: 10, serverAliveInterval: 2, serverAliveCountMax: 2)
        try await assertAskPassSession(
            target: password,
            knownHosts: knownHosts,
            askPassHelper: askPassHelper,
            response: "osxterm",
            label: "password authentication"
        )

        var encryptedKey = ConnectionProfile(
            name: "encrypted-key",
            host: "127.0.0.1",
            port: targetPort,
            username: "osxterm",
            authentication: .privateKey(path: encryptedPrivateKey.path, passphrase: SecretReference())
        )
        encryptedKey.options = SSHOptions(connectTimeout: 10, serverAliveInterval: 2, serverAliveCountMax: 2)
        try await assertAskPassSession(
            target: encryptedKey,
            knownHosts: knownHosts,
            askPassHelper: askPassHelper,
            response: "integration-key-passphrase",
            label: "encrypted private key authentication"
        )

        let interactive = ConnectionProfile(
            name: "keyboard-interactive",
            host: "127.0.0.1",
            port: targetPort,
            username: "osxterm",
            authentication: .keyboardInteractive(secret: nil),
            options: SSHOptions(connectTimeout: 10, serverAliveInterval: 2, serverAliveCountMax: 2)
        )
        try await assertAskPassSession(
            target: interactive,
            knownHosts: knownHosts,
            askPassHelper: askPassHelper,
            response: "osxterm",
            label: "keyboard-interactive authentication"
        )

        let certificateProfile = ConnectionProfile(
            name: "certificate",
            host: "127.0.0.1",
            port: certificateTargetPort,
            username: "osxterm",
            authentication: .privateKey(path: privateKey.path, passphrase: nil),
            certificatePath: certificate.path,
            options: SSHOptions(connectTimeout: 10, serverAliveInterval: 2, serverAliveCountMax: 2)
        )
        try await assertSession(
            target: certificateProfile,
            profiles: [certificateProfile],
            knownHosts: knownHosts,
            proxyHelper: nil,
            label: "OpenSSH user certificate authentication"
        )

        try await assertAgentSession(
            targetPort: targetPort,
            privateKey: privateKey,
            knownHosts: knownHosts
        )
    }

    private static func assertAskPassSession(
        target: ConnectionProfile,
        knownHosts: URL,
        askPassHelper: URL,
        response: String,
        label: String
    ) async throws {
        let broker = try SessionCredentialBroker(responses: ["default": response])
        defer { broker.stop() }
        try await assertSession(
            target: target,
            profiles: [target],
            knownHosts: knownHosts,
            proxyHelper: nil,
            label: label,
            environment: askPassEnvironment(askPassHelper: askPassHelper, broker: broker)
        )
    }

    private static func assertAgentSession(
        targetPort: Int,
        privateKey: URL,
        knownHosts: URL
    ) async throws {
        let agent = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-agent"),
            arguments: ["-s"],
            environment: ProcessInfo.processInfo.environment
        )
        guard agent.status == 0,
              let socket = shellAssignment(named: "SSH_AUTH_SOCK", in: agent.output),
              let processID = shellAssignment(named: "SSH_AGENT_PID", in: agent.output)
        else {
            throw IntegrationRunnerError.invocationFailed("Could not start the SSH agent for integration validation.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = socket
        environment["SSH_AGENT_PID"] = processID
        defer {
            _ = try? runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-agent"),
                arguments: ["-k"],
                environment: environment
            )
        }
        let added = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-add"),
            arguments: [privateKey.path],
            environment: environment
        )
        guard added.status == 0 else {
            throw IntegrationRunnerError.invocationFailed("Could not add the integration key to SSH agent: \(added.error)")
        }
        let target = ConnectionProfile(
            name: "agent",
            host: "127.0.0.1",
            port: targetPort,
            username: "osxterm",
            authentication: .agent(socketPath: socket),
            options: SSHOptions(connectTimeout: 10, serverAliveInterval: 2, serverAliveCountMax: 2)
        )
        try await assertSession(
            target: target,
            profiles: [target],
            knownHosts: knownHosts,
            proxyHelper: nil,
            label: "SSH agent authentication",
            environment: environment
        )
    }

    private static func shellAssignment(named name: String, in output: String) -> String? {
        let prefix = "\(name)="
        guard let range = output.range(of: prefix) else { return nil }
        let suffix = output[range.upperBound...]
        guard let delimiter = suffix.firstIndex(of: ";") else { return nil }
        let value = String(suffix[..<delimiter])
        return value.isEmpty ? nil : value
    }

    private static func assertSFTPTransfer(
        target: ConnectionProfile,
        knownHosts: URL,
        fixtureDirectory: URL
    ) async throws {
        let route = try SSHRouteResolver.resolve(target: target, profiles: [target])
        let prepared = try OpenSSHCommandCompiler().prepare(
            route: route,
            knownHostsURL: knownHosts,
            hostKeyPolicy: .requireKnown,
            purpose: .subsystem("sftp"),
            baseDirectory: FileManager.default.temporaryDirectory
        )
        let transport = try SFTPProcessTransport(
            preparedCommand: prepared,
            environment: ProcessInfo.processInfo.environment
        )
        let client = SFTPClient(transport: transport)
        defer { Task { await transport.close() } }
        _ = try await client.initialize()
        let directory = try SFTPRemotePath(rawValue: "integration-runner")
        do {
            try await client.makeDirectory(directory)
        } catch let error as SFTPClientError {
            guard case let .remoteStatus(_, status, _) = error, status == .failure else { throw error }
        }
        let remote = try SFTPRemotePath(rawValue: "integration-runner/한글 file 'quote'.txt")
        let expected = Data("osXterm SFTP v3 integration\n".utf8)
        let handle = try await client.open(path: remote, flags: [.write, .create, .truncate])
        try await client.write(expected, to: handle, offset: 0)
        try await client.close(handle)
        let attributes = try await client.attributes(of: remote)
        guard attributes.size == UInt64(expected.count) else {
            throw IntegrationRunnerError.assertionFailed("Structured SFTP attribute size did not match uploaded content.")
        }
        let entries = try await client.listDirectory(directory)
        guard entries.contains(where: { $0.filename == "한글 file 'quote'.txt" }) else {
            throw IntegrationRunnerError.assertionFailed("Structured SFTP directory listing omitted the quoted Unicode file name.")
        }
        try await assertLargeResumableSFTPTransfer(
            client: client,
            directory: directory,
            fixtureDirectory: fixtureDirectory
        )
    }

    /// Transfers 100 MiB through structured SFTP in two phases. The second
    /// phase resumes an already written remote prefix only after matching the
    /// stored source fingerprint and the actual prefix digest, then verifies
    /// a streamed SHA-256 digest.
    private static func assertLargeResumableSFTPTransfer(
        client: SFTPClient,
        directory: SFTPRemotePath,
        fixtureDirectory: URL
    ) async throws {
        let byteCount = 100 * 1024 * 1024
        let chunk = Data((0 ..< 64 * 1024).map { UInt8($0 % 251) })
        let remote = try SFTPRemotePath(rawValue: "\(directory.rawValue)/resumable-100MiB.bin")
        let sourceURL = fixtureDirectory.appendingPathComponent("resumable-100MiB-source.bin")
        let destinationURL = fixtureDirectory.appendingPathComponent("resumable-100MiB-download.bin")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: destinationURL)

        guard FileManager.default.createFile(atPath: sourceURL.path, contents: nil) else {
            throw IntegrationRunnerError.invocationFailed("Could not create the large SFTP integration source file.")
        }
        let sourceWriter = try FileHandle(forWritingTo: sourceURL)
        var expectedHasher = SHA256()
        for _ in stride(from: 0, to: byteCount, by: chunk.count) {
            try sourceWriter.write(contentsOf: chunk)
            expectedHasher.update(data: chunk)
        }
        try sourceWriter.close()
        let expectedDigest = Data(expectedHasher.finalize())
        let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let sourceSize = sourceValues.fileSize, sourceSize == byteCount else {
            throw IntegrationRunnerError.assertionFailed("The large SFTP source file has an unexpected size.")
        }
        let sourceFingerprint = TransferSourceFingerprint(
            size: Int64(sourceSize),
            modificationTime: sourceValues.contentModificationDate
        )

        let partialByteCount = 8 * 1024 * 1024
        let initialHandle = try await client.open(path: remote, flags: [.write, .create, .truncate])
        let sourceReader = try FileHandle(forReadingFrom: sourceURL)
        do {
            var offset: UInt64 = 0
            while offset < UInt64(partialByteCount) {
                let data = try sourceReader.read(upToCount: chunk.count) ?? Data()
                guard !data.isEmpty else {
                    throw IntegrationRunnerError.assertionFailed("The large SFTP source ended before its planned partial prefix.")
                }
                try await client.write(data, to: initialHandle, offset: offset)
                offset += UInt64(data.count)
            }
            try await client.close(initialHandle)
        } catch {
            try? await client.close(initialHandle)
            throw error
        }
        try sourceReader.close()

        let partialAttributes = try await client.attributes(of: remote, followSymlink: false)
        guard let partialSize = partialAttributes.size else {
            throw IntegrationRunnerError.assertionFailed("The resumable SFTP prefix has no reported size.")
        }
        let prefixDigestMatches = try await SFTPResumeIntegrityVerifier(client: client).localAndRemotePrefixMatch(
            localURL: sourceURL,
            remotePath: remote,
            byteCount: Int64(partialSize)
        )
        let decision = TransferResumePlanner.decide(
            existingDestinationBytes: Int64(partialSize),
            previousSource: sourceFingerprint,
            currentSource: sourceFingerprint,
            prefixDigestMatches: prefixDigestMatches
        )
        guard case let .resume(fromOffset) = decision, fromOffset == Int64(partialByteCount) else {
            throw IntegrationRunnerError.assertionFailed("The resumable SFTP transfer did not retain a verified prefix.")
        }
        let rejectedDecision = TransferResumePlanner.decide(
            existingDestinationBytes: Int64(partialSize),
            previousSource: sourceFingerprint,
            currentSource: sourceFingerprint,
            prefixDigestMatches: false
        )
        guard rejectedDecision == .restart else {
            throw IntegrationRunnerError.assertionFailed("The resumable SFTP transfer accepted an unverified prefix.")
        }

        let resumedHandle = try await client.open(path: remote, flags: [.write, .create])
        let resumedReader = try FileHandle(forReadingFrom: sourceURL)
        do {
            try resumedReader.seek(toOffset: UInt64(partialByteCount))
            var offset = UInt64(partialByteCount)
            while true {
                let data = try resumedReader.read(upToCount: chunk.count) ?? Data()
                if data.isEmpty { break }
                try await client.write(data, to: resumedHandle, offset: offset)
                offset += UInt64(data.count)
            }
            try await client.close(resumedHandle)
        } catch {
            try? await client.close(resumedHandle)
            throw error
        }
        try resumedReader.close()

        let completeAttributes = try await client.attributes(of: remote, followSymlink: false)
        guard completeAttributes.size == UInt64(byteCount) else {
            throw IntegrationRunnerError.assertionFailed("The resumed SFTP upload does not have the expected 100 MiB size.")
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw IntegrationRunnerError.invocationFailed("Could not create the large SFTP integration download file.")
        }
        let destinationWriter = try FileHandle(forWritingTo: destinationURL)
        let downloadHandle = try await client.open(path: remote, flags: [.read])
        var downloadedHasher = SHA256()
        do {
            var offset: UInt64 = 0
            while let data = try await client.read(from: downloadHandle, offset: offset, length: UInt32(chunk.count)) {
                try destinationWriter.write(contentsOf: data)
                downloadedHasher.update(data: data)
                offset += UInt64(data.count)
            }
            try await client.close(downloadHandle)
        } catch {
            try? await client.close(downloadHandle)
            throw error
        }
        try destinationWriter.close()
        guard Data(downloadedHasher.finalize()) == expectedDigest else {
            throw IntegrationRunnerError.assertionFailed("The resumed 100 MiB SFTP transfer failed SHA-256 integrity verification.")
        }
    }

    private static func assertAuthenticatedProxySessions(
        target: ConnectionProfile,
        knownHosts: URL,
        proxyHelper: URL,
        httpPort: Int,
        socksPort: Int
    ) async throws {
        let username = "osxterm-proxy"
        let password = "integration-proxy-password"
        for (label, kind, port) in [
            ("HTTP CONNECT Basic proxy", ProxyKind.httpConnect, httpPort),
            ("SOCKS5 user/password proxy", ProxyKind.socks5, socksPort)
        ] {
            let broker = try SessionCredentialBroker(
                responses: [
                    ProxyCredentialPrompt.make(username: username, host: "127.0.0.1", port: port): password
                ]
            )
            defer { broker.stop() }
            var proxied = target
            proxied.id = UUID()
            proxied.name = label
            proxied.proxy = ProxyConfiguration(
                kind: kind,
                host: "127.0.0.1",
                port: port,
                username: username,
                password: SecretReference()
            )
            try await assertSession(
                target: proxied,
                profiles: [proxied],
                knownHosts: knownHosts,
                proxyHelper: ProxyHelperLaunchConfiguration(
                    executableURL: proxyHelper,
                    socketPath: broker.socketPath,
                    token: broker.token,
                    sessionID: UUID()
                ),
                label: label
            )
        }
    }

    private static func assertSCPTransfer(
        target: ConnectionProfile,
        knownHosts: URL,
        fixtureDirectory: URL
    ) throws {
        let route = try SSHRouteResolver.resolve(target: target, profiles: [target])
        let source = fixtureDirectory.appendingPathComponent("scp-한글-file.txt")
        let download = fixtureDirectory.appendingPathComponent("scp-downloaded-한글-file.txt")
        let expected = Data("osXterm SCP through SFTP integration\n".utf8)
        try expected.write(to: source, options: .atomic)
        try? FileManager.default.removeItem(at: download)

        let uploadTask = TransferTask(
            profileID: target.id,
            direction: .scpUpload,
            localURL: source,
            remotePath: "integration-runner/scp-한글-file.txt"
        )
        let uploadPlan = try TransferPlanner.plan(uploadTask)
        let upload = try OpenSSHCommandCompiler().prepareSCP(
            route: route,
            knownHostsURL: knownHosts,
            hostKeyPolicy: .requireKnown,
            baseDirectory: FileManager.default.temporaryDirectory
        )
        defer { upload.configuration.cleanup() }
        let remoteOperand = "\(upload.configuration.targetAlias):\(uploadPlan.remotePath.rawValue)"
        let uploadResult = try runProcess(
            executable: upload.invocation.executableURL,
            arguments: upload.invocation.arguments + ["-s", uploadPlan.localURL.path, remoteOperand],
            environment: ProcessInfo.processInfo.environment
        )
        guard uploadResult.status == 0 else {
            throw IntegrationRunnerError.invocationFailed("SCP upload through the app route failed: \(uploadResult.error)")
        }

        let downloadTask = TransferTask(
            profileID: target.id,
            direction: .scpDownload,
            localURL: download,
            remotePath: uploadPlan.remotePath.rawValue
        )
        let downloadPlan = try TransferPlanner.plan(downloadTask)
        let fetched = try OpenSSHCommandCompiler().prepareSCP(
            route: route,
            knownHostsURL: knownHosts,
            hostKeyPolicy: .requireKnown,
            baseDirectory: FileManager.default.temporaryDirectory
        )
        defer { fetched.configuration.cleanup() }
        let downloadResult = try runProcess(
            executable: fetched.invocation.executableURL,
            arguments: fetched.invocation.arguments + [
                "-s",
                "\(fetched.configuration.targetAlias):\(downloadPlan.remotePath.rawValue)",
                downloadPlan.localURL.path
            ],
            environment: ProcessInfo.processInfo.environment
        )
        guard downloadResult.status == 0,
              try Data(contentsOf: download) == expected
        else {
            throw IntegrationRunnerError.invocationFailed("SCP download through the app route did not preserve file data: \(downloadResult.error)")
        }
    }

    private static func assertTunnelForwarding(
        target: ConnectionProfile,
        restrictedTargetPort: Int,
        knownHosts: URL,
        echoPort: Int
    ) async throws {
        let basePort = 24800
        let local = ForwardingRule(
            name: "integration local",
            kind: .local,
            listenPort: basePort + 1,
            destinationHost: "tcp-echo",
            destinationPort: 9000
        )
        let localTunnel = try startTunnel(rule: local, target: target, knownHosts: knownHosts)
        defer { localTunnel.stop() }
        try await assertLocalEcho(
            arguments: ["-w", "3", "127.0.0.1", String(basePort + 1)],
            expected: "local-forward",
            tunnel: localTunnel,
            label: "local forwarding"
        )
        try await assertDestinationProbe(rule: local, label: "local forwarding")

        let duplicate = ForwardingRule(
            name: "integration local conflict",
            kind: .local,
            listenPort: basePort + 1,
            destinationHost: "tcp-echo",
            destinationPort: 9000
        )
        let duplicateTunnel = try startTunnel(rule: duplicate, target: target, knownHosts: knownHosts)
        defer { duplicateTunnel.stop() }
        try await assertTunnelFails(duplicateTunnel, label: "local forwarding port collision")

        let dynamic = ForwardingRule(
            name: "integration dynamic",
            kind: .dynamic,
            listenPort: basePort + 2
        )
        let dynamicTunnel = try startTunnel(rule: dynamic, target: target, knownHosts: knownHosts)
        defer { dynamicTunnel.stop() }
        try await assertLocalEcho(
            arguments: [
                "-w", "3", "-x", "127.0.0.1:\(basePort + 2)", "-X", "5",
                "127.0.0.1", String(echoPort)
            ],
            expected: "dynamic-forward",
            tunnel: dynamicTunnel,
            label: "dynamic SOCKS forwarding"
        )

        let localSocketPath = "/tmp/osxterm-integration-local.sock"
        try? FileManager.default.removeItem(atPath: localSocketPath)
        let localSocket = ForwardingRule(
            name: "integration local socket",
            kind: .localUnix,
            listenPath: localSocketPath,
            destinationHost: "tcp-echo",
            destinationPort: 9000
        )
        let localSocketTunnel = try startTunnel(rule: localSocket, target: target, knownHosts: knownHosts)
        defer {
            localSocketTunnel.stop()
            try? FileManager.default.removeItem(atPath: localSocketPath)
        }
        try await assertLocalEcho(
            arguments: ["-w", "3", "-U", localSocketPath],
            expected: "local-unix-forward",
            tunnel: localSocketTunnel,
            label: "local Unix socket forwarding"
        )
        try await assertDestinationProbe(rule: localSocket, label: "local Unix socket forwarding")

        let remote = ForwardingRule(
            name: "integration remote",
            kind: .remote,
            listenPort: basePort + 3,
            destinationHost: "127.0.0.1",
            destinationPort: echoPort
        )
        let remoteTunnel = try startTunnel(rule: remote, target: target, knownHosts: knownHosts)
        defer { remoteTunnel.stop() }
        try await assertRemoteEcho(
            target: target,
            knownHosts: knownHosts,
            command: "printf remote-forward | nc -w 3 127.0.0.1 \(basePort + 3)",
            expected: "remote-forward",
            tunnel: remoteTunnel,
            label: "remote forwarding"
        )

        let remoteDynamic = ForwardingRule(
            name: "integration remote dynamic",
            kind: .remoteDynamic,
            listenPort: basePort + 4
        )
        let remoteDynamicTunnel = try startTunnel(rule: remoteDynamic, target: target, knownHosts: knownHosts)
        defer { remoteDynamicTunnel.stop() }
        try await assertRemoteEcho(
            target: target,
            knownHosts: knownHosts,
            command: "printf remote-dynamic-forward | nc -w 3 -x 127.0.0.1:\(basePort + 4) -X 5 127.0.0.1 \(echoPort)",
            expected: "remote-dynamic-forward",
            tunnel: remoteDynamicTunnel,
            label: "remote dynamic forwarding"
        )

        let remoteSocketPath = "/tmp/osxterm-integration-remote.sock"
        let remoteSocket = ForwardingRule(
            name: "integration remote socket",
            kind: .remoteUnix,
            listenPath: remoteSocketPath,
            destinationHost: "127.0.0.1",
            destinationPort: echoPort
        )
        let remoteSocketTunnel = try startTunnel(rule: remoteSocket, target: target, knownHosts: knownHosts)
        defer { remoteSocketTunnel.stop() }
        try await assertRemoteEcho(
            target: target,
            knownHosts: knownHosts,
            command: "printf remote-unix-forward | nc -w 3 -U \(remoteSocketPath)",
            expected: "remote-unix-forward",
            tunnel: remoteSocketTunnel,
            label: "remote Unix socket forwarding"
        )

        let automaticRemote = ForwardingRule(
            name: "integration remote automatic port",
            kind: .remote,
            listenPort: 0,
            destinationHost: "127.0.0.1",
            destinationPort: echoPort
        )
        let automaticTunnel = try startTunnel(rule: automaticRemote, target: target, knownHosts: knownHosts)
        defer { automaticTunnel.stop() }
        let allocatedPort = try await waitForAllocatedPort(
            rule: automaticRemote,
            tunnel: automaticTunnel,
            label: "remote automatic port allocation"
        )
        try await assertRemoteEcho(
            target: target,
            knownHosts: knownHosts,
            command: "printf remote-allocated-forward | nc -w 3 127.0.0.1 \(allocatedPort)",
            expected: "remote-allocated-forward",
            tunnel: automaticTunnel,
            label: "remote automatic port forwarding"
        )

        let restricted = ConnectionProfile(
            name: "restricted forwarding",
            host: "127.0.0.1",
            port: restrictedTargetPort,
            username: "osxterm",
            authentication: target.authentication,
            options: target.options
        )
        let denied = ForwardingRule(
            name: "integration denied",
            kind: .local,
            listenPort: basePort + 5,
            destinationHost: "127.0.0.1",
            destinationPort: echoPort
        )
        let deniedTunnel = try startTunnel(rule: denied, target: restricted, knownHosts: knownHosts)
        defer { deniedTunnel.stop() }
        try await assertTunnelFails(deniedTunnel, label: "server forwarding policy rejection")
    }

    private static func startTunnel(
        rule: ForwardingRule,
        target: ConnectionProfile,
        knownHosts: URL
    ) throws -> IntegrationTunnel {
        let route = try SSHRouteResolver.resolve(target: target, profiles: [target])
        let prepared = try OpenSSHCommandCompiler().prepare(
            route: route,
            knownHostsURL: knownHosts,
            hostKeyPolicy: .requireKnown,
            purpose: .tunnel,
            forwardingRules: [rule],
            baseDirectory: FileManager.default.temporaryDirectory
        )
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = prepared.invocation.executableURL
        process.arguments = prepared.invocation.arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        let tunnel = IntegrationTunnel(
            process: process,
            preparedCommand: prepared,
            standardOutput: standardOutput,
            standardError: standardError
        )
        do {
            try process.run()
            return tunnel
        } catch {
            tunnel.stop()
            throw error
        }
    }

    private static func assertLocalEcho(
        arguments: [String],
        expected: String,
        tunnel: IntegrationTunnel,
        label: String
    ) async throws {
        let input = Data(expected.utf8)
        for _ in 0 ..< 40 {
            if !tunnel.process.isRunning {
                throw IntegrationRunnerError.invocationFailed("\(label) tunnel exited: \(tunnel.diagnostics)")
            }
            if let result = try? runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/nc"),
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment,
                input: input
            ), result.status == 0, result.output == expected {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntegrationRunnerError.assertionFailed("\(label) did not carry a complete echo response: \(tunnel.diagnostics)")
    }

    private static func assertRemoteEcho(
        target: ConnectionProfile,
        knownHosts: URL,
        command: String,
        expected: String,
        tunnel: IntegrationTunnel,
        label: String
    ) async throws {
        for _ in 0 ..< 40 {
            if !tunnel.process.isRunning {
                throw IntegrationRunnerError.invocationFailed("\(label) tunnel exited: \(tunnel.diagnostics)")
            }
            do {
                try await assertSession(
                    target: target,
                    profiles: [target],
                    knownHosts: knownHosts,
                    proxyHelper: nil,
                    label: label,
                    command: command,
                    expectedOutput: expected
                )
                return
            } catch {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw IntegrationRunnerError.assertionFailed("\(label) did not carry a complete echo response: \(tunnel.diagnostics)")
    }

    private static func assertTunnelFails(_ tunnel: IntegrationTunnel, label: String) async throws {
        for _ in 0 ..< 40 {
            if !tunnel.process.isRunning {
                guard tunnel.process.terminationStatus != 0 else {
                    throw IntegrationRunnerError.assertionFailed("\(label) unexpectedly exited successfully.")
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntegrationRunnerError.assertionFailed("\(label) kept running instead of reporting its failure.")
    }

    private static func assertDestinationProbe(
        rule: ForwardingRule,
        assignedPort: Int? = nil,
        label: String
    ) async throws {
        guard let target = TunnelDestinationProbe.target(for: rule, assignedPort: assignedPort) else {
            throw IntegrationRunnerError.assertionFailed("\(label) did not provide a probeable destination.")
        }
        guard await TunnelDestinationProbe.probe(target) == .reachable else {
            throw IntegrationRunnerError.assertionFailed("\(label) listener did not reach its configured destination.")
        }
    }

    private static func waitForAllocatedPort(
        rule: ForwardingRule,
        tunnel: IntegrationTunnel,
        label: String
    ) async throws -> Int {
        for _ in 0 ..< 40 {
            if !tunnel.process.isRunning {
                throw IntegrationRunnerError.invocationFailed("\(label) tunnel exited: \(tunnel.diagnostics)")
            }
            let events = OpenSSHTunnelOutputParser.events(in: tunnel.diagnostics, rules: [rule])
            if case let .listenerReady(_, assignedPort?) = events.last {
                return assignedPort
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntegrationRunnerError.assertionFailed("\(label) did not report a listener port: \(tunnel.diagnostics)")
    }

    private final class IntegrationTunnel {
        let process: Process
        private let preparedCommand: PreparedOpenSSHCommand
        private let standardOutput: Pipe
        private let standardError: Pipe
        private let diagnosticBuffer = TunnelDiagnosticBuffer()

        init(
            process: Process,
            preparedCommand: PreparedOpenSSHCommand,
            standardOutput: Pipe,
            standardError: Pipe
        ) {
            self.process = process
            self.preparedCommand = preparedCommand
            self.standardOutput = standardOutput
            self.standardError = standardError
            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
            let diagnosticBuffer = self.diagnosticBuffer
            standardError.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                diagnosticBuffer.append(data)
            }
        }

        var diagnostics: String {
            diagnosticBuffer.text
        }

        func stop() {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            preparedCommand.configuration.cleanup()
        }

        deinit { stop() }
    }

    /// Only this lock-protected byte buffer is shared with FileHandle's
    /// background callback. Process ownership remains with IntegrationTunnel.
    private final class TunnelDiagnosticBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var standardErrorData = Data()

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: standardErrorData, as: UTF8.self)
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            let maximum = 64 * 1024
            if standardErrorData.count + data.count > maximum {
                standardErrorData = Data(standardErrorData.suffix(max(0, maximum - data.count)))
            }
            standardErrorData.append(data)
        }
    }

    private static func required(_ name: String, _ environment: [String: String]) throws -> String {
        guard let value = environment[name], !value.isEmpty else { throw IntegrationRunnerError.missingEnvironment(name) }
        return value
    }

    private static func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osxterm-integration-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func port(_ name: String, _ environment: [String: String]) throws -> Int {
        guard let value = Int(try required(name, environment)), (1 ... 65_535).contains(value) else {
            throw IntegrationRunnerError.missingEnvironment(name)
        }
        return value
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data? = nil
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        // OpenSSH verbose output can exceed a pipe's capacity. Capture both
        // streams in private temporary files so waitUntilExit cannot deadlock
        // while a child waits for an unread stdout or stderr pipe to drain.
        let captureDirectory = try temporaryDirectory(named: "process-output")
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        for url in [outputURL, errorURL] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw IntegrationRunnerError.invocationFailed("Could not create private process capture file.")
            }
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? error.close() }
        let inputPipe = input.map { _ in Pipe() }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = output
        process.standardError = error
        try process.run()
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }
}
