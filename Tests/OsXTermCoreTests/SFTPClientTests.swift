import Foundation
import Testing
@testable import OsXTermCore

@Suite
struct SFTPClientTests {
    @Test
    func testSystemRunnerExecutesAsynchronouslyAndCapturesOutput() async throws {
        let input = Data("batch input\n".utf8)

        let result = try await SystemSFTPProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: input,
            environment: [:]
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput == input)
        #expect(result.standardError.isEmpty)
    }

    @Test
    func testBuildsStructuredInvocationForJumpHostAgentAndOptions() async throws {
        let runner = SFTPRecordingRunner()
        let configuration = SFTPConnectionConfiguration(
            host: "2001:db8::10",
            port: 2222,
            username: "deploy",
            identityFileURL: URL(fileURLWithPath: "/tmp/id key"),
            sshConfigFileURL: URL(fileURLWithPath: "/tmp/ssh config"),
            jumpHosts: [
                SFTPJumpHost(
                    host: "2001:db8::20",
                    port: 2200,
                    username: "jump"
                )
            ],
            sshAgentSocketPath: "/tmp/agent.sock",
            sshOptions: [
                SFTPSSHOption(name: "ServerAliveInterval", value: "30")
            ],
            environment: ["OSXTERM_TEST": "enabled"]
        )
        let client = SFTPClient(configuration: configuration, processRunner: runner)

        try await client.makeDirectory(
            remotePath: #"/srv/a "quote" * [x] \ file"#
        )

        let recordedInvocations = await runner.invocations()
        let invocation = try #require(recordedInvocations.first)
        #expect(invocation.executableURL == SFTPClient.systemExecutableURL)
        #expect(
            invocation.arguments == [
                "-q", "-b", "-", "-P", "2222",
                "-F", "/tmp/ssh config",
                "-i", "/tmp/id key",
                "-J", "jump@[2001:db8::20]:2200",
                "-o", "ServerAliveInterval=30",
                "deploy@[2001:db8::10]"
            ]
        )
        #expect(invocation.environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        #expect(invocation.environment["OSXTERM_TEST"] == "enabled")
        #expect(
            String(decoding: invocation.standardInput, as: UTF8.self)
                == "mkdir \"/srv/a \\\"quote\\\" \\* \\[x\\] \\\\ file\"\n"
        )
    }

    @Test
    func testAskPassEnvironmentDoesNotEnableAuthenticationBlockingBatchMode() async throws {
        let runner = SFTPRecordingRunner()
        let client = SFTPClient(
            configuration: SFTPConnectionConfiguration(
                host: "server.example.com",
                username: "deploy",
                environment: [
                    "SSH_ASKPASS": "/Applications/osXterm.app/Contents/MacOS/osXtermAskPass"
                ]
            ),
            processRunner: runner
        )

        try await client.makeDirectory(remotePath: "/srv/app")

        let recordedInvocations = await runner.invocations()
        let invocation = try #require(recordedInvocations.first)
        #expect(!invocation.arguments.contains("-b"))
    }

    @Test
    func testEncodesAllFileOperationsAsLiteralBatchPaths() async throws {
        let runner = SFTPRecordingRunner()
        let client = SFTPClient(
            configuration: SFTPConnectionConfiguration(
                host: "server.example.com",
                username: "user"
            ),
            processRunner: runner
        )

        try await client.upload(
            localURL: URL(fileURLWithPath: "/tmp/local file*"),
            to: "/remote/upload target"
        )
        try await client.download(
            remotePath: "/remote/report?.txt",
            to: URL(fileURLWithPath: "/tmp/download target")
        )
        try await client.makeDirectory(remotePath: "/remote/new directory")
        try await client.rename(
            remotePath: "/remote/old[name]",
            to: "/remote/new name"
        )
        try await client.remove(remotePath: "-rf")

        let batches = await runner.invocations().map {
            String(decoding: $0.standardInput, as: UTF8.self)
        }
        #expect(
            batches == [
                "put \"/tmp/local file\\*\" \"/remote/upload target\"\n",
                "get \"/remote/report\\?.txt\" \"/tmp/download target\"\n",
                "mkdir \"/remote/new directory\"\n",
                "rename \"/remote/old\\[name\\]\" \"/remote/new name\"\n",
                "rm \"./-rf\"\n"
            ]
        )
    }

    @Test
    func testListPreservesSpacesAndRemovesOnlyLineTerminators() async throws {
        let runner = SFTPRecordingRunner(
            result: SFTPProcessResult(
                terminationStatus: 0,
                standardOutput: Data("alpha\nfile with spaces\r\n".utf8)
            )
        )
        let client = SFTPClient(
            configuration: SFTPConnectionConfiguration(host: "host"),
            processRunner: runner
        )

        let entries = try await client.list(remotePath: "/srv")

        #expect(entries == ["alpha", "file with spaces"])
    }

    @Test
    func testListEntriesClassifiesDirectoriesAndHidesDotFiles() async throws {
        let runner = SFTPRecordingRunner(
            result: SFTPProcessResult(
                terminationStatus: 0,
                standardOutput: Data(
                    "drwxr-xr-x    2 user group 64 Jan  1 00:00 folder\n-rw-r--r--    1 user group 7 Jan  1 00:00 file with spaces\n-rw-r--r--    1 user group 3 Jan  1 00:00 .hidden\n".utf8
                )
            )
        )
        let client = SFTPClient(
            configuration: SFTPConnectionConfiguration(host: "host"),
            processRunner: runner
        )

        let entries = try await client.listEntries(remotePath: "/srv")

        #expect(
            entries == [
                SFTPRemoteEntry(name: "folder", isDirectory: true),
                SFTPRemoteEntry(name: "file with spaces", isDirectory: false)
            ]
        )
    }

    @Test
    func testRejectsBatchLineInjectionBeforeLaunchingProcess() async {
        let runner = SFTPRecordingRunner()
        let client = SFTPClient(
            configuration: SFTPConnectionConfiguration(host: "host"),
            processRunner: runner
        )

        do {
            try await client.remove(remotePath: "/safe\nrm /other")
            Issue.record("Expected invalid path error")
        } catch let error as SFTPError {
            guard case .invalidPath = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let invocationCount = await runner.invocations().count
        #expect(invocationCount == 0)
    }

    @Test
    func testRejectsEndpointValuesThatCouldBecomeOptions() async {
        let runner = SFTPRecordingRunner()
        let client = SFTPClient(
            configuration: SFTPConnectionConfiguration(
                host: "host",
                username: "-oProxyCommand=unexpected"
            ),
            processRunner: runner
        )

        do {
            try await client.makeDirectory(remotePath: "/srv/app")
            Issue.record("Expected invalid configuration error")
        } catch let error as SFTPError {
            guard case .invalidConfiguration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let invocationCount = await runner.invocations().count
        #expect(invocationCount == 0)
    }

    @Test
    func testSurfacesExitStatusAndStandardError() async {
        let runner = SFTPRecordingRunner(
            result: SFTPProcessResult(
                terminationStatus: 1,
                standardError: Data("Permission denied\n".utf8)
            )
        )
        let client = SFTPClient(
            configuration: SFTPConnectionConfiguration(host: "host"),
            processRunner: runner
        )

        do {
            try await client.remove(remotePath: "/protected")
            Issue.record("Expected command failure")
        } catch let error as SFTPError {
            #expect(
                error == .commandFailed(status: 1, standardError: "Permission denied")
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct SFTPRecordedInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let standardInput: Data
    let environment: [String: String]
}

private actor SFTPRecordingRunner: SFTPProcessRunning {
    private let result: SFTPProcessResult
    private var recordedInvocations: [SFTPRecordedInvocation] = []

    init(result: SFTPProcessResult = SFTPProcessResult(terminationStatus: 0)) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        environment: [String: String]
    ) async throws -> SFTPProcessResult {
        recordedInvocations.append(
            SFTPRecordedInvocation(
                executableURL: executableURL,
                arguments: arguments,
                standardInput: standardInput,
                environment: environment
            )
        )
        return result
    }

    func invocations() -> [SFTPRecordedInvocation] {
        recordedInvocations
    }
}
