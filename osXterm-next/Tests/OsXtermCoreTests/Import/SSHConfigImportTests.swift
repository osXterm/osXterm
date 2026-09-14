import Foundation
import Testing
@testable import OsXtermCore

@Suite
struct SSHConfigImportTests {
    @Test
    func importsIncludesWildcardsAndProxyJumpProfileReferences() throws {
        let main = URL(fileURLWithPath: "/fixtures/config")
        let extra = URL(fileURLWithPath: "/fixtures/conf.d/extra.conf")
        let importer = SSHConfigImporter(
            sourceLoader: MemoryConfigLoader(
                files: [
                    main: """
                    Include conf.d/*.conf
                    Host *.corp
                        ServerAliveInterval 9
                    Host app.corp
                        HostName app.internal.example
                        User deploy
                        Port 2200
                        IdentityFile \"/Users/test/.ssh/id work\"
                        ProxyJump jump
                    Host jump
                        HostName jump.internal.example
                        User relay
                    """,
                    extra: """
                    Host app.corp
                        CertificateFile /Users/test/.ssh/id-cert.pub
                        ForwardAgent yes
                    """
                ],
                includes: [
                    "conf.d/*.conf": [extra]
                ]
            )
        )

        let result = try importer.import(from: main)
        let app = try #require(result.profiles.first(where: { $0.alias == "app.corp" }))
        let jump = try #require(result.profiles.first(where: { $0.alias == "jump" }))

        #expect(app.host == "app.internal.example")
        #expect(app.port == 2200)
        #expect(app.username == "deploy")
        #expect(app.identityFiles == ["/Users/test/.ssh/id work"])
        #expect(app.certificateFile == "/Users/test/.ssh/id-cert.pub")
        #expect(app.options.serverAliveInterval == 9)
        #expect(app.options.forwardAgent)
        #expect(app.proxyJump == ["jump"])

        let persisted = result.connectionProfiles(date: Date(timeIntervalSince1970: 0))
        let persistedApp = try #require(persisted.first(where: { $0.id == app.id }))
        #expect(persistedApp.jumpProfileIDs == [jump.id])
        #expect(persistedApp.authentication == .privateKey(
            path: "/Users/test/.ssh/id work",
            passphrase: nil
        ))
    }

    @Test
    func rejectsMatchExecAndNeverTreatsProxyCommandAsExecutable() throws {
        let importer = SSHConfigImporter(sourceLoader: MemoryConfigLoader())
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("osxterm-import-\(UUID().uuidString)")
        let result = try importer.import(text: """
        Host safe
            HostName safe.example
            ProxyCommand touch \(sentinel.path)
        Match exec \"touch \(sentinel.path)\"
            User untrusted
        Host next
            HostName next.example
        """)

        let safe = try #require(result.profiles.first(where: { $0.alias == "safe" }))
        let next = try #require(result.profiles.first(where: { $0.alias == "next" }))
        #expect(safe.unsupportedDirectives.map(\.keyword) == ["proxycommand"])
        #expect(next.username.isEmpty)
        #expect(result.diagnostics.contains {
            $0.message.contains("ProxyCommand") && $0.message.contains("not executed")
        })
        #expect(result.diagnostics.contains { $0.message.contains("Match exec") })
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test
    func wildcardNegationDoesNotApplyItsDirectivesToExcludedAliases() throws {
        let importer = SSHConfigImporter(sourceLoader: MemoryConfigLoader())
        let result = try importer.import(text: """
        Host *.example !private.example
            User shared
        Host public.example private.example
            HostName target.example
        """)

        let publicProfile = try #require(result.profiles.first(where: { $0.alias == "public.example" }))
        let privateProfile = try #require(result.profiles.first(where: { $0.alias == "private.example" }))
        #expect(publicProfile.username == "shared")
        #expect(privateProfile.username.isEmpty)
    }

    @Test
    func reportsMalformedValuesWithoutCreatingUnsafeProfileSettings() throws {
        let importer = SSHConfigImporter(sourceLoader: MemoryConfigLoader())
        let result = try importer.import(text: """
        Host broken
            Port 70000
            ServerAliveCountMax -1
            ForwardAgent not-a-bool
            RequestTTY maybe
        """)

        let profile = try #require(result.profiles.first)
        #expect(profile.port == 22)
        #expect(profile.options.serverAliveCountMax == SSHOptions.default.serverAliveCountMax)
        #expect(profile.options.forwardAgent == false)
        #expect(profile.options.requestTTY == SSHOptions.default.requestTTY)
        #expect(result.diagnostics.filter { $0.severity == .warning }.count == 4)
    }

    @Test
    func detectsIncludeCyclesBeforeProducingAProfile() {
        let first = URL(fileURLWithPath: "/fixtures/first")
        let second = URL(fileURLWithPath: "/fixtures/second")
        let importer = SSHConfigImporter(
            sourceLoader: MemoryConfigLoader(
                files: [
                    first: "Include second",
                    second: "Include first"
                ],
                includes: [
                    "first": [first],
                    "second": [second]
                ]
            )
        )

        #expect(throws: SSHConfigImportError.includeCycle(first)) {
            _ = try importer.import(from: first)
        }
    }
}

private struct MemoryConfigLoader: SSHConfigSourceLoading {
    let files: [URL: String]
    let includes: [String: [URL]]

    init(files: [URL: String] = [:], includes: [String: [URL]] = [:]) {
        self.files = files
        self.includes = includes
    }

    func contents(of source: URL) throws -> String {
        guard let contents = files[source] else {
            throw SSHConfigImportError.unreadableSource(source, "No fixture source")
        }
        return contents
    }

    func resolveIncludes(pattern: String, relativeTo _: URL) throws -> [URL] {
        includes[pattern] ?? []
    }
}
