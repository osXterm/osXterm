import Darwin
import Foundation
import OsXTermCore
import UniformTypeIdentifiers

private struct RecordedSFTPInvocation: Sendable {
    let arguments: [String]
    let standardInput: Data
    let environment: [String: String]
}

private actor RecordingSFTPRunner: SFTPProcessRunning {
    private let result: SFTPProcessResult
    private var values: [RecordedSFTPInvocation] = []

    init(result: SFTPProcessResult = SFTPProcessResult(terminationStatus: 0)) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        environment: [String: String]
    ) async throws -> SFTPProcessResult {
        values.append(
            RecordedSFTPInvocation(
                arguments: arguments,
                standardInput: standardInput,
                environment: environment
            )
        )
        return result
    }

    func invocations() -> [RecordedSFTPInvocation] {
        values
    }
}

private struct BlockingSFTPRunner: SFTPProcessRunning {
    let delay: TimeInterval

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        environment: [String: String]
    ) async throws -> SFTPProcessResult {
        let deadline = Date().addingTimeInterval(delay)
        while Date() < deadline {
            _ = Date().timeIntervalSinceReferenceDate
        }
        return SFTPProcessResult(terminationStatus: 0)
    }
}

@main
private struct OsXTermChecks {
    @MainActor
    static func main() async {
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                print("[PASS] \(message)")
            } else {
                failures.append(message)
                print("[FAIL] \(message)")
            }
        }

        check(
            SSHSessionExitDisposition(status: 0) == .returnToHome,
            "Normal SSH exit returns to the home screen"
        )
        check(
            SSHSessionExitDisposition(status: 255) == .retainFailure(status: 255),
            "Failed SSH exit remains available for retry"
        )

        do {
            let jumpProfile = SSHProfile(
                id: UUID(),
                name: "Bastion",
                host: "bastion.example.com",
                port: 2200,
                username: "jump"
            )
            let profile = SSHProfile(
                id: UUID(),
                name: "Production",
                host: "server.example.com",
                port: 2222,
                username: "deploy",
                authentication: .agent(socketPath: "/tmp/agent.sock"),
                agentForwarding: true,
                jumpHostProfileIDs: [jumpProfile.id]
            )

            let encoded = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(SSHProfile.self, from: encoded)
            check(profile == decoded, "Profile settings round trip")

            let route = try SSHRouteResolver.resolve(target: profile, profiles: [jumpProfile, profile])
            let routeConfiguration = try SSHRouteConfiguration(route: route)
            defer { try? FileManager.default.removeItem(at: routeConfiguration.directoryURL) }
            let command = try SSHCommandBuilder().build(
                route: route,
                configuration: routeConfiguration
            )
            check(command.arguments.contains("-tt"), "Interactive SSH requests a remote PTY")
            check(command.arguments.contains("-A"), "Agent forwarding is profile controlled")
            let routeConfigData = try Data(contentsOf: routeConfiguration.fileURL)
            let routeConfigPermissions = try FileManager.default.attributesOfItem(
                atPath: routeConfiguration.fileURL.path
            )[.posixPermissions] as? NSNumber
            check(
                String(decoding: routeConfigData, as: UTF8.self).contains("HostName server.example.com"),
                "OpenSSH can read the generated route config"
            )
            let controlPath = String(decoding: routeConfigData, as: UTF8.self)
                .split(separator: "\n")
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ControlPath ") })
                .map { $0.trimmingCharacters(in: .whitespaces).dropFirst("ControlPath ".count) }
                .map(String.init)
            check(
                controlPath.map { $0.count <= 100 } == true,
                "SSH ControlPath stays below the macOS Unix socket limit"
            )
            check(
                routeConfigPermissions.map { $0.intValue & 0o777 == 0o600 } == true,
                "Generated route config is private to the current user"
            )
            check(
                route.hops.map(\.id) == [jumpProfile.id],
                "JumpHost route is preserved"
            )
            let relay = SSHProfile(
                name: "Relay",
                host: "relay.example.com",
                username: "relay"
            )
            let nestedJump = SSHProfile(
                name: "Nested bastion",
                host: "nested-bastion.example.com",
                username: "jump",
                jumpHostProfileIDs: [relay.id]
            )
            let nestedTarget = SSHProfile(
                name: "Nested target",
                host: "nested.internal",
                username: "app",
                jumpHostProfileIDs: [nestedJump.id]
            )
            let nestedRoute = try SSHRouteResolver.resolve(
                target: nestedTarget,
                profiles: [relay, nestedJump, nestedTarget]
            )
            check(
                nestedRoute.hops.map(\.id) == [relay.id, nestedJump.id],
                "Recursive JumpHost route is ordered from outer to inner"
            )
            let duplicateTarget = SSHProfile(
                name: "Duplicate target",
                host: "duplicate.internal",
                username: "app",
                jumpHostProfileIDs: [nestedJump.id, relay.id]
            )
            do {
                _ = try SSHRouteResolver.resolve(
                    target: duplicateTarget,
                    profiles: [relay, nestedJump, duplicateTarget]
                )
                check(false, "Duplicate JumpHost references are rejected")
            } catch SSHRouteError.duplicateReference(let id) {
                check(id == relay.id, "Duplicate JumpHost references are rejected")
            } catch {
                check(false, "Duplicate JumpHost references are rejected")
            }
            check(
                command.arguments.contains("-F")
                    && command.arguments.last == routeConfiguration.targetAlias,
                "SSH uses the generated route configuration"
            )
            let routeConfigText = String(
                decoding: try Data(contentsOf: routeConfiguration.fileURL),
                as: UTF8.self
            )
            check(
                routeConfigText.contains("IdentityAgent /tmp/agent.sock"),
                "Selected ssh-agent socket is written to the route"
            )
            check(
                !command.arguments.contains(where: { $0.hasPrefix("-L") || $0.hasPrefix("-R") || $0.hasPrefix("-D") }),
                "Port forwarding is not emitted"
            )
            let proxied = SSHProfile(
                name: "Proxy target",
                host: "proxy-target.example.com",
                username: "deploy",
                proxy: .socks5(host: "127.0.0.1", port: 1080, username: "proxy-user")
            )
            let proxyRoute = try SSHRouteResolver.resolve(target: proxied, profiles: [proxied])
            let proxyConfiguration = try SSHRouteConfiguration(route: proxyRoute)
            defer { try? FileManager.default.removeItem(at: proxyConfiguration.directoryURL) }
            let proxyText = String(
                decoding: try Data(contentsOf: proxyConfiguration.fileURL),
                as: UTF8.self
            )
            check(
                proxyText.contains("ProxyCommand /usr/bin/nc -X 5")
                    && proxyText.contains("-P 'proxy-user'"),
                "Proxy transport is preserved in the generated route"
            )
        } catch {
            failures.append("SSH command planning: \(error)")
            print("[FAIL] SSH command planning: \(error)")
        }

        do {
            let combinedTarget = SSHProfile(
                name: "Realm endpoint",
                host: "10.173.11.15",
                username: "hwjeong@sysadmin@10.171.30.22"
            )
            let command = try SSHCommandBuilder().build(for: combinedTarget)
            check(
                argument(after: "-l", in: command.arguments)
                    == "hwjeong@sysadmin@10.171.30.22",
                "Separate Host keeps the literal username"
            )
            check(
                command.arguments.last == "10.173.11.15",
                "Separate Host remains the SSH destination"
            )

            let sftpConfiguration = try SFTPConnectionConfiguration(profile: combinedTarget)
            check(
                sftpConfiguration.username == "hwjeong@sysadmin@10.171.30.22"
                    && sftpConfiguration.host == "10.173.11.15",
                "SFTP keeps the literal username and separate Host"
            )
        } catch {
            failures.append("Combined username target: \(error)")
            print("[FAIL] Combined username target: \(error)")
        }

        do {
            let passwordProfile = SSHProfile(
                name: "Password",
                host: "server.example.com",
                username: "deploy",
                authentication: .password
            )
            let command = try SSHCommandBuilder().build(for: passwordProfile)
            let encodedProfile = try JSONEncoder().encode(passwordProfile)
            let encodedProfileText = String(decoding: encodedProfile, as: UTF8.self)
            check(
                command.requiresAskPass,
                "Password profiles require a session AskPass bridge"
            )
            check(
                !encodedProfileText.contains("secret") && !encodedProfileText.contains("password-reference"),
                "Password profiles persist no password or secret reference"
            )
        } catch {
            failures.append("Password command planning: \(error)")
            print("[FAIL] Password command planning: \(error)")
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osxterm-password-cipher-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let keyURL = directory.appendingPathComponent(".password-key")
            let cipher = ProfilePasswordCipher(keyURL: keyURL)
            let password = "fixture-password-123"
            let encrypted = try cipher.encrypt(password)
            let profile = SSHProfile(
                name: "Encrypted",
                host: "server.example.com",
                username: "deploy",
                authentication: .password,
                encryptedPassword: encrypted
            )
            let profileJSON = String(
                decoding: try JSONEncoder().encode(profile),
                as: UTF8.self
            )
            let decrypted = try cipher.decrypt(encrypted)
            check(
                decrypted == password,
                "Profile password ciphertext decrypts with the local AES-GCM key"
            )
            check(
                !profileJSON.contains(password) && profileJSON.contains("encryptedPassword"),
                "Profile JSON contains ciphertext but no plaintext password"
            )
        } catch {
            failures.append("Profile password encryption: \(error)")
            print("[FAIL] Profile password encryption: \(error)")
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osxterm-profile-migration-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let profileURL = directory.appendingPathComponent("profiles.json")
            let legacyProfile = """
            [{
              "agentForwarding": false,
              "authentication": {"password": {"secretID": "legacy-reference"}},
              "forwards": [],
              "host": "server.example.com",
              "id": "\(UUID().uuidString)",
              "jumpHosts": [],
              "name": "Legacy password profile",
              "port": 22,
              "proxy": null,
              "username": "deploy"
            }]
            """
            try Data(legacyProfile.utf8).write(to: profileURL)

            let store = try ProfileStore(fileURL: profileURL)
            let profiles = try await store.load()
            let rewritten = try Data(contentsOf: profileURL)
            check(
                profiles.first?.authentication == .password,
                "Legacy password profiles migrate to a password prompt"
            )
            check(
                !String(decoding: rewritten, as: UTF8.self).contains("secretID"),
                "Profile migration removes the legacy password reference from disk"
            )
        } catch {
            failures.append("Profile credential migration: \(error)")
            print("[FAIL] Profile credential migration: \(error)")
        }

        let legacyTarget = SSHProfile(
            name: "Legacy route target",
            host: "target.internal",
            username: "deploy",
            jumpHosts: [
                SSHJumpHost(
                    host: "jump.example.com",
                    port: 2200,
                    username: "jumper"
                )
            ]
        )
        let migrated = SSHRouteResolver.migrateLegacyProfiles([legacyTarget])
        let generated = migrated.first { $0.id != legacyTarget.id }
        check(
            migrated.count == 2
                && generated.map { migrated.first?.jumpHostProfileIDs == [$0.id] } == true
                && generated?.name == "Migrated Jump Host jump.example.com",
            "Legacy manual JumpHost settings migrate to a saved profile reference"
        )

        do {
            _ = try ProfileStore()
            check(
                true,
                "Default profile store initializes from the user's .config directory"
            )
        } catch {
            failures.append("Default profile store initialization: \(error)")
            print("[FAIL] Default profile store initialization: \(error)")
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osxterm-profile-recovery-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let profileURL = directory.appendingPathComponent("profiles.json")
            let keyURL = directory.appendingPathComponent(".password-key")
            try Data("[]".utf8).write(to: profileURL)
            try Data(repeating: 7, count: 32).write(to: keyURL)
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profileURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyURL.path)

            let store = try ProfileStore(fileURL: profileURL)
            let backupURL = try await store.recoverUnreadableConfiguration()
            check(
                fileManager.fileExists(atPath: backupURL.appendingPathComponent("profiles.json").path)
                    && fileManager.fileExists(atPath: backupURL.appendingPathComponent(".password-key").path),
                "Profile recovery backs up the JSON and password key together"
            )
            try await store.save([])
            check(
                fileManager.fileExists(atPath: profileURL.path),
                "Profile recovery creates a fresh writable settings file"
            )
        } catch {
            failures.append("Profile recovery: \(error)")
            print("[FAIL] Profile recovery: \(error)")
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osxterm-ghostty-theme-check-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let ghosttyDirectory = directory.appendingPathComponent("ghostty", isDirectory: true)
            let themesDirectory = ghosttyDirectory.appendingPathComponent("themes", isDirectory: true)
            try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
            try Data(
                """
                background = #112233
                foreground = #ddeeff
                cursor-color = #abcdef
                palette = 1=#ff0000
                """.utf8
            ).write(to: themesDirectory.appendingPathComponent("Example Theme"))
            try Data(
                """
                theme = Example Theme
                foreground = #010203
                font-family = Agave
                font-family = D2CodingLigature Nerd Font Mono
                font-size = 18
                font-codepoint-map = U+AC00-U+D7A3=Orbit
                """.utf8
            )
                .write(to: ghosttyDirectory.appendingPathComponent("config"))

            let catalog = GhosttyThemeCatalog.load(
                isDarkAppearance: true,
                environment: ["XDG_CONFIG_HOME": directory.path],
                homeDirectory: directory,
                themeDirectories: [themesDirectory]
            )
            let configured = catalog.themes.first { $0.id == catalog.configuredThemeID }
            let example = catalog.themes.first { $0.name == "Example Theme" }
            check(
                configured?.colors.background == "#112233"
                    && configured?.colors.foreground == "#010203"
                    && configured?.colors.palette[1] == "#ff0000",
                "Ghostty config applies theme colors and overrides"
            )
            check(
                example?.source == "User theme" && catalog.themes.count >= 2,
                "Ghostty user themes are discovered"
            )
            check(
                catalog.fontConfiguration.families == [
                    "Agave",
                    "D2CodingLigature Nerd Font Mono"
                ]
                    && catalog.fontConfiguration.size == 18
                    && catalog.fontConfiguration.mappedFamily(for: "가") == "Orbit",
                "Ghostty font families, size, and codepoint maps are loaded"
            )
            let explicitCatalog = GhosttyThemeCatalog.load(
                isDarkAppearance: true,
                environment: [:],
                homeDirectory: directory,
                themeDirectories: [themesDirectory],
                configurationPath: ghosttyDirectory.appendingPathComponent("config").path
            )
            check(
                explicitCatalog.fontConfiguration.primaryFamily == "Agave"
                    && explicitCatalog.themes.first(where: { $0.id == explicitCatalog.configuredThemeID })?.fileURL?.path
                        == ghosttyDirectory.appendingPathComponent("config").path,
                "Ghostty catalog accepts an explicit configuration path"
            )
        } catch {
            failures.append("Ghostty theme catalog: \(error)")
            print("[FAIL] Ghostty theme catalog: \(error)")
        }

        do {
            let server = try SessionAskPassServer(credential: "session-only-password")
            defer { server.stop() }

            let response = try SessionAskPassClient.readCredential(socketPath: server.socketPath)
            check(
                response == Data("session-only-password\n".utf8),
                "AskPass bridge returns an in-memory session credential"
            )
            let permissions = try FileManager.default.attributesOfItem(atPath: server.socketPath)[.posixPermissions]
                as? NSNumber
            check(
                permissions.map { $0.intValue & 0o777 == 0o600 } == true,
                "AskPass socket is private to the active user"
            )
        } catch {
            failures.append("Session AskPass bridge: \(error)")
            print("[FAIL] Session AskPass bridge: \(error)")
        }

        do {
            var tracker = OSC7PathTracker()
            let first = tracker.ingest(Data("\u{001B}]7;file://host/srv/My%20".utf8))
            let second = tracker.ingest(Data("Project\u{0007}".utf8))
            check(first.isEmpty, "OSC 7 parser buffers partial sequences")
            check(
                second.last?.path == "/srv/My Project",
                "OSC 7 parser tracks and decodes the remote path"
            )
        }

        do {
            var sanitizer = ANSITextSanitizer()
            let visible = sanitizer.consume(
                Data("\u{001B}[32mready\u{001B}[0m\u{001B}]7;file:///tmp\u{0007}".utf8)
            ) + sanitizer.finish()
            check(visible == "ready", "Terminal text removes ANSI and OSC control sequences")
        }

        do {
            let terminal = try GhosttyTerminalEngine(
                columns: 80,
                rows: 24,
                maxScrollback: 200
            )
            let snapshot = terminal.ingest(
                Data(
                    "\u{001B}[32mGhostty ready\u{001B}[0m\r\n\u{001B}]7;file://server/srv/My%20Project\u{0007}".utf8
                )
            )

            check(
                snapshot.text.contains("Ghostty ready") && !snapshot.text.contains("\u{001B}[32m"),
                "Ghostty VT owns ANSI parsing and formatted screen state"
            )
            let styledReadyCell = snapshot.styledScreen?.rows
                .flatMap(\.cells)
                .first(where: { $0.text == "G" })
            check(
                styledReadyCell?.foreground == .palette(2),
                "Ghostty VT exposes ANSI color codes as styled cells"
            )
            let styledAttributeCell = terminal.ingest(
                Data("\u{001B}[1;31;44mX\u{001B}[0m".utf8)
            ).styledScreen?.rows
                .flatMap(\.cells)
                .first(where: { $0.text == "X" })
            check(
                styledAttributeCell?.bold == true
                    && styledAttributeCell?.foreground == .palette(1)
                    && styledAttributeCell?.background == .palette(4),
                "Ghostty VT preserves ANSI bold and background colors"
            )
            let styledTrueColorCell = terminal.ingest(
                Data("\u{001B}[38;2;1;2;3mY\u{001B}[0m".utf8)
            ).styledScreen?.rows
                .flatMap(\.cells)
                .first(where: { $0.text == "Y" })
            check(
                styledTrueColorCell?.foreground == .rgb(
                    GhosttyTerminalRGB(red: 1, green: 2, blue: 3)
                ),
                "Ghostty VT preserves true-color ANSI sequences"
            )
            let koreanSnapshot = terminal.ingest(Data("한글 입력 테스트".utf8))
            let koreanCells = koreanSnapshot.styledScreen?.rows
                .flatMap(\.cells)
                .map(\.text)
                .joined() ?? ""
            check(
                koreanSnapshot.text.contains("한글 입력 테스트")
                    && koreanCells.contains("한글 입력 테스트"),
                "Ghostty VT preserves UTF-8 Korean graphemes"
            )
            let widthSnapshot = terminal.ingest(Data("\u{E0B2}\u{E0B0}한".utf8))
            let widthCells = widthSnapshot.styledScreen?.rows.flatMap(\.cells) ?? []
            let powerlineCell = widthCells.first { $0.text == "\u{E0B2}" }
            let koreanCell = widthCells.first { $0.text == "한" }
            check(
                powerlineCell?.columnSpan == .narrow && koreanCell?.columnSpan == .wide,
                "Ghostty VT preserves Powerline and wide-cell spans"
            )
            let rowOrderSnapshot = terminal.ingest(Data("\r\nTOP\r\nBOTTOM".utf8))
            let rowOrder = rowOrderSnapshot.styledScreen?.rows.map { row in
                row.cells.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            } ?? []
            check(
                (rowOrder.firstIndex(of: "TOP") ?? .max)
                    < (rowOrder.firstIndex(of: "BOTTOM") ?? .min),
                "Ghostty VT rows are ordered from top to bottom"
            )
            check(
                snapshot.remotePath == "/srv/My Project",
                "Ghostty VT exposes OSC working-directory updates for SFTP"
            )
            check(
                terminal.resize(
                    columns: 100,
                    rows: 30,
                    cellWidthPixels: 16,
                    cellHeightPixels: 28
                ),
                "Ghostty VT accepts terminal resize updates"
            )

            _ = terminal.ingest(Data("initial setup command\r\n".utf8))
            _ = terminal.ingest(Data("\u{001B}[3J\u{001B}[2J\u{001B}[H".utf8))
            check(
                !terminal.snapshot().text.contains("initial setup command"),
                "Ghostty VT applies screen clear sequences without shell injection"
            )

            let historyTerminal = try GhosttyTerminalEngine(
                columns: 60,
                rows: 5,
                maxScrollback: 64
            )
            let historyOutput = (0 ..< 24)
                .map { "history-line-\($0)\r\n" }
                .joined()
            _ = historyTerminal.ingest(Data(historyOutput.utf8))
            let latestHistory = historyTerminal.snapshot()
            let oldestHistory = historyTerminal.scroll(by: -10_000)
            let restoredHistory = historyTerminal.scrollToBottom()
            check(
                latestHistory.scrollbar.isScrollable
                    && latestHistory.scrollbar.isAtBottom
                    && oldestHistory.scrollbar.offset == 0
                    && !oldestHistory.scrollbar.isAtBottom
                    && restoredHistory.scrollbar.isAtBottom,
                "Ghostty VT scrollback moves independently from the terminal frame"
            )
            check(
                oldestHistory.styledScreen?.rows
                    .flatMap(\.cells)
                    .contains(where: { $0.text == "h" }) == true,
                "Ghostty VT renders rows from the retained scrollback"
            )

            let cursorTerminal = try GhosttyTerminalEngine(columns: 40, rows: 5)
            let blockCursor = cursorTerminal.ingest(Data("cursor".utf8)).cursor
            let barCursor = cursorTerminal.ingest(Data("\u{001B}[5 q".utf8)).cursor
            let underlineCursor = cursorTerminal.ingest(Data("\u{001B}[3 q".utf8)).cursor
            let hiddenCursor = cursorTerminal.ingest(Data("\u{001B}[?25l".utf8)).cursor
            check(
                blockCursor.visible && blockCursor.hasViewportPosition,
                "Ghostty VT exposes the visible cursor position"
            )
            check(
                barCursor.style == .bar && underlineCursor.style == .underline,
                "Ghostty VT exposes bar and underline cursor styles"
            )
            check(
                !hiddenCursor.visible,
                "Ghostty VT exposes cursor visibility changes"
            )
        } catch {
            failures.append("Ghostty VT integration: \(error)")
            print("[FAIL] Ghostty VT integration: \(error)")
        }

        do {
            let terminal = try GhosttyTerminalEngine(columns: 80, rows: 24)
            let session = SSHSession(
                command: SSHCommand(
                    executableURL: URL(fileURLWithPath: "/bin/cat"),
                    arguments: []
                ),
                configuration: SSHSessionConfiguration(
                    usesPseudoTerminal: true,
                    terminalColumns: 80,
                    terminalRows: 24
                )
            )
            let output = session.output

            try await session.start()
            try await session.send(Data("ghostty-pty-input-ok\r".utf8))
            try await Task.sleep(for: .milliseconds(150))
            try await session.terminate()

            for await event in output {
                switch event {
                case let .standardOutput(data), let .standardError(data):
                    _ = terminal.ingest(data)
                case .terminated:
                    break
                }
            }

            check(
                terminal.snapshot().text.contains("ghostty-pty-input-ok"),
                "Raw terminal input crosses the PTY and renders through Ghostty VT"
            )
        } catch {
            failures.append("Ghostty PTY path: \(error)")
            print("[FAIL] Ghostty PTY path: \(error)")
        }

        do {
            let runner = RecordingSFTPRunner(
                result: SFTPProcessResult(
                    terminationStatus: 0,
                    standardOutput: Data(
                        "drwxr-xr-x    2 user group 64 Jan  1 00:00 folder\n-rw-r--r--    1 user group 7 Jan  1 00:00 file with spaces\n-rw-r--r--    1 user group 3 Jan  1 00:00 .hidden\n".utf8
                    )
                )
            )
            let client = SFTPClient(
                configuration: SFTPConnectionConfiguration(host: "server.example.com"),
                processRunner: runner
            )
            let entries = try await client.listEntries(remotePath: "/srv")
            check(
                entries == [
                    SFTPRemoteEntry(name: "folder", isDirectory: true),
                    SFTPRemoteEntry(name: "file with spaces", isDirectory: false)
                ],
                "SFTP hides dot files and preserves directory types"
            )
        } catch {
            failures.append("SFTP listing metadata: \(error)")
            print("[FAIL] SFTP listing metadata: \(error)")
        }

        do {
            let runner = RecordingSFTPRunner()
            let client = SFTPClient(
                configuration: SFTPConnectionConfiguration(
                    host: "server.example.com",
                    port: 2222,
                    username: "deploy",
                    jumpHosts: [
                        SFTPJumpHost(
                            host: "bastion.example.com",
                            port: 2200,
                            username: "jump"
                        )
                    ],
                    sshAgentSocketPath: "/tmp/agent.sock"
                ),
                processRunner: runner
            )
            try await client.makeDirectory(remotePath: "/srv/My Project")
            let invocation = await runner.invocations().first

            check(
                invocation?.arguments.contains("-J") == true,
                "SFTP uses the configured JumpHost"
            )
            check(
                invocation?.environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock",
                "SFTP uses the selected ssh-agent socket"
            )
            check(
                invocation.map {
                    String(decoding: $0.standardInput, as: UTF8.self)
                        == "mkdir \"/srv/My Project\"\n"
                } == true,
                "SFTP batch paths are quoted"
            )
        } catch {
            failures.append("SFTP command planning: \(error)")
            print("[FAIL] SFTP command planning: \(error)")
        }

        do {
            let client = SFTPClient(
                configuration: SFTPConnectionConfiguration(host: "server.example.com"),
                processRunner: BlockingSFTPRunner(delay: 0.25)
            )
            let operation = Task {
                try await SFTPExecutor.run(client: client) { client in
                    try await client.list(remotePath: "/")
                }
            }
            let startedAt = Date()
            try await Task.sleep(for: .milliseconds(40))
            let elapsed = Date().timeIntervalSince(startedAt)
            let terminal = try GhosttyTerminalEngine(columns: 80, rows: 24)
            let snapshot = terminal.ingest(Data("ssh-output-remains-responsive".utf8))
            _ = try await operation.value

            check(
                elapsed < 0.18 && snapshot.text.contains("ssh-output-remains-responsive"),
                "SFTP work does not stall SSH terminal processing"
            )
        } catch {
            failures.append("SFTP and SSH isolation: \(error)")
            print("[FAIL] SFTP and SSH isolation: \(error)")
        }

        do {
            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osxterm-drag-check-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: exportDirectory)
            }

            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            let sourceURL = exportDirectory.appendingPathComponent("remote export.txt")
            let expectedData = Data("drag export content\n".utf8)
            try expectedData.write(to: sourceURL)

            check(
                SFTPDragAndDropSupport.fileURL(
                    from: sourceURL.dataRepresentation as NSData
                ) == sourceURL,
                "SFTP drop parser accepts Finder file URL data"
            )

            let finderProvider = NSItemProvider(
                item: sourceURL as NSURL,
                typeIdentifier: UTType.fileURL.identifier
            )
            let droppedURL = try await loadDroppedFileURL(
                from: finderProvider,
                typeIdentifier: UTType.fileURL.identifier
            )
            check(
                droppedURL == sourceURL,
                "SFTP drop parser accepts a Finder file URL provider"
            )

            var exports = 0
            let provider = SFTPDragAndDropSupport.remoteFileProvider(
                suggestedFilename: sourceURL.lastPathComponent
            ) {
                exports += 1
                return sourceURL
            }

            check(
                provider.hasRepresentationConforming(
                    toTypeIdentifier: UTType.data.identifier,
                    fileOptions: []
                ),
                "SFTP remote drag registers a file representation"
            )

            let exportedData = try await loadFileRepresentation(
                from: provider,
                typeIdentifier: UTType.data.identifier
            )
            check(exports == 1, "SFTP remote drag invokes the deferred exporter")
            check(exportedData == expectedData, "SFTP remote drag supplies the downloaded file")
        } catch {
            failures.append("SFTP drag and drop: \(error)")
            print("[FAIL] SFTP drag and drop: \(error)")
        }

        guard failures.isEmpty else {
            print("\n\(failures.count) osXterm check(s) failed.")
            exit(1)
        }

        print("\nAll osXterm core checks passed.")
    }

    private static func argument(after option: String, in arguments: [String]) -> String? {
        guard
            let index = arguments.firstIndex(of: option),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    @MainActor
    private static func loadFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "osXtermChecks",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "File provider returned no file URL."
                            ]
                        )
                    )
                    return
                }

                do {
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private static func loadDroppedFileURL(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url = SFTPDragAndDropSupport.fileURL(from: item) else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "osXtermChecks",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Finder provider returned no file URL."
                            ]
                        )
                    )
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
