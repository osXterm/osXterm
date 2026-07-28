import AppKit
import Foundation
import OsXTermCore
import SwiftUI

@MainActor
final class TerminalSessionViewModel: ObservableObject, Identifiable {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(Int32)
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                "Not connected"
            case .connecting:
                "Connecting"
            case .connected:
                "Connected"
            case let .disconnected(status):
                "Disconnected (\(status))"
            case let .failed(message):
                "Failed: \(message)"
            }
        }
    }

    let id = UUID()
    let profile: SSHProfile
    var onNormalExit: (() -> Void)?

    @Published private(set) var state: ConnectionState = .idle
    private(set) var transcript = ""
    @Published private(set) var styledScreen: GhosttyTerminalStyledScreen?
    private(set) var cursor = GhosttyTerminalCursor.hidden
    private(set) var scrollbar = GhosttyTerminalScrollbar.empty
    @Published private(set) var currentRemotePath = "/"
    @Published private(set) var remoteEntries: [SFTPRemoteEntry] = []
    @Published private(set) var isLoadingFiles = false
    @Published private(set) var fileError: String?

    private var session: SSHSession?
    private var outputTask: Task<Void, Never>?
    private var snapshotPresentationTask: Task<Void, Never>?
    private var sftpRefreshTask: Task<Void, Never>?
    private var commandRefreshTask: Task<Void, Never>?
    private var commandRefreshPending = false
    private var sftpRefreshGeneration = 0
    private var terminalEngine: GhosttyTerminalEngine?
    private var osc7PathTracker = OSC7PathTracker()
    private let route: ResolvedSSHRoute
    private let routeConfiguration: SSHRouteConfiguration
    private var credentials: [String: String]
    private var askPassServer: SessionAskPassServer?

    init(
        route: ResolvedSSHRoute,
        routeConfiguration: SSHRouteConfiguration,
        credentials: [String: String]
    ) {
        self.profile = route.target
        self.route = route
        self.routeConfiguration = routeConfiguration
        self.credentials = credentials
    }

    deinit {
        outputTask?.cancel()
        snapshotPresentationTask?.cancel()
        sftpRefreshTask?.cancel()
        commandRefreshTask?.cancel()
    }

    func connect() async {
        guard state == .idle else {
            return
        }

        do {
            state = .connecting
            commandRefreshTask?.cancel()
            commandRefreshTask = nil
            commandRefreshPending = false
            osc7PathTracker.reset()
            let command = try SSHCommandBuilder().build(
                route: route,
                configuration: routeConfiguration
            )
            askPassServer = try makeAskPassServerIfNeeded()
            terminalEngine = try GhosttyTerminalEngine(
                columns: 120,
                rows: 36,
                maxScrollback: 5_000
            )
            let environment = authenticationEnvironment()
            let newSession = SSHSession(
                command: command,
                askPassPath: askPassHelperPath(),
                configuration: SSHSessionConfiguration(
                    environmentOverrides: environment,
                    usesPseudoTerminal: true,
                    terminalColumns: 120,
                    terminalRows: 36
                )
            )
            session = newSession

            outputTask = Task { [weak self, output = newSession.output] in
                for await event in output {
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.consume(event)
                }
            }

            try await newSession.start()
            state = .connected

            refreshSFTP()
        } catch {
            askPassServer?.stop()
            askPassServer = nil
            clearSessionCredentials()
            state = .failed(error.localizedDescription)
            transcript.append("Connection failed: \(error.localizedDescription)\n")
        }
    }

    func disconnect() async {
        sftpRefreshTask?.cancel()
        commandRefreshTask?.cancel()
        commandRefreshTask = nil
        commandRefreshPending = false
        guard let session else {
            askPassServer?.stop()
            askPassServer = nil
            clearSessionCredentials()
            return
        }
        try? await session.terminate()
        askPassServer?.stop()
        askPassServer = nil
        clearSessionCredentials()
    }

    func send(line: String) async {
        guard !line.isEmpty else {
            return
        }
        await send(data: Data((line + "\r").utf8))
    }

    var isTerminalInputReady: Bool {
        state == .connected
    }

    /// Sends exact terminal bytes, including control keys and pasted text.
    /// The terminal surface calls this instead of reducing interaction to
    /// complete command lines.
    func send(data: Data) async {
        guard let session, !data.isEmpty else {
            return
        }
        scrollTerminalToBottom()
        do {
            try await session.send(data)
            // Typing and editing a command must not start an SFTP process for
            // every character. Refresh the listing only when the user submits
            // a command or paste containing a line terminator.
            if data.contains(0x0D) || data.contains(0x0A) {
                requestSFTPRefreshAfterCommand()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func scrollTerminal(by rows: Int) {
        guard rows != 0, let terminalEngine else {
            return
        }
        applyTerminalSnapshot(terminalEngine.scroll(by: rows))
    }

    func scrollTerminalToBottom() {
        guard let terminalEngine else {
            return
        }
        let maxOffset = scrollbar.totalRows > scrollbar.viewportRows
            ? scrollbar.totalRows - scrollbar.viewportRows
            : 0
        if maxOffset > 0, scrollbar.offset < maxOffset {
            applyTerminalSnapshot(terminalEngine.scrollToBottom())
        } else {
            terminalEngine.scrollToBottomWithoutSnapshot()
        }
    }

    func scrollTerminal(to offset: UInt64) {
        guard let terminalEngine else { return }
        applyTerminalSnapshot(terminalEngine.scroll(to: offset))
    }

    func resizeTerminal(
        columns: Int,
        rows: Int,
        cellWidthPixels: Int = 0,
        cellHeightPixels: Int = 0
    ) async {
        _ = terminalEngine?.resize(
            columns: columns,
            rows: rows,
            cellWidthPixels: cellWidthPixels,
            cellHeightPixels: cellHeightPixels
        )

        guard let session else {
            return
        }
        do {
            try await session.resizeTerminal(columns: columns, rows: rows)
        } catch {
            // A resize failure must not end an otherwise healthy session.
            transcript.append("Terminal resize failed: \(error.localizedDescription)\n")
        }
    }

    func navigate(to path: String) {
        currentRemotePath = normalizeRemotePath(path)
        refreshSFTP()
    }

    func navigateUp() {
        guard currentRemotePath != "/" else {
            return
        }
        let parent = URL(fileURLWithPath: currentRemotePath)
            .deletingLastPathComponent()
            .path
        navigate(to: parent)
    }

    func openEntry(_ name: String) {
        let candidate = appendRemotePath(name)
        let previousPath = currentRemotePath
        currentRemotePath = candidate
        scheduleSFTPRefresh(at: candidate, restorePath: previousPath)
    }

    func upload(localURL: URL) async {
        do {
            let client = try makeSFTPClient()
            let remotePath = appendRemotePath(localURL.lastPathComponent)
            try await SFTPExecutor.run(client: client) { client in
                try await client.upload(localURL: localURL, to: remotePath)
            }
            refreshSFTP()
        } catch {
            fileError = error.localizedDescription
        }
    }

    func download(entry name: String, to localURL: URL) async {
        await download(remotePath: appendRemotePath(name), to: localURL)
    }

    /// Resolves an entry before an asynchronous export begins so a later
    /// terminal-directory update cannot redirect that export elsewhere.
    func remotePath(for entry: String) -> String {
        appendRemotePath(entry)
    }

    func download(remotePath: String, to localURL: URL) async {
        do {
            let client = try makeSFTPClient()
            let normalizedPath = normalizeRemotePath(remotePath)
            try await SFTPExecutor.run(client: client) { client in
                try await client.download(remotePath: normalizedPath, to: localURL)
            }
            fileError = nil
        } catch {
            fileError = error.localizedDescription
        }
    }

    /// Starts a directory listing without joining the SSH output consumer.
    /// Each listing owns a separate `sftp` process and runs off the main actor,
    /// so a slow server or a stalled directory cannot delay terminal bytes.
    func refreshSFTP() {
        scheduleSFTPRefresh(at: currentRemotePath)
    }

    private func scheduleSFTPRefresh(at path: String, restorePath: String? = nil) {
        sftpRefreshGeneration += 1
        let generation = sftpRefreshGeneration
        let requestedPath = normalizeRemotePath(path)
        sftpRefreshTask?.cancel()
        isLoadingFiles = true

        do {
            let client = try makeSFTPClient()
            sftpRefreshTask = Task { [weak self] in
                do {
                    let entries = try await SFTPExecutor.run(client: client) { client in
                        try await client.listEntries(remotePath: requestedPath)
                    }
                    guard let self,
                          !Task.isCancelled,
                          self.sftpRefreshGeneration == generation
                    else {
                        return
                    }

                    self.remoteEntries = entries.sorted { lhs, rhs in
                        if lhs.isDirectory != rhs.isDirectory {
                            return lhs.isDirectory
                        }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    self.fileError = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          self.sftpRefreshGeneration == generation
                    else {
                        return
                    }

                    self.remoteEntries = []
                    self.fileError = error.localizedDescription
                    if let restorePath,
                       self.currentRemotePath == requestedPath
                    {
                        self.currentRemotePath = restorePath
                        self.scheduleSFTPRefresh(at: restorePath)
                    }
                }

                if let self,
                   self.sftpRefreshGeneration == generation
                {
                    self.isLoadingFiles = false
                    self.sftpRefreshTask = nil
                }
            }
        } catch {
            isLoadingFiles = false
            remoteEntries = []
            fileError = error.localizedDescription
        }
    }

    private func consume(_ event: SSHSessionOutput) async {
        switch event {
        case let .standardOutput(data), let .standardError(data):
            guard let terminalEngine else {
                return
            }

            let pathUpdates = osc7PathTracker.ingest(data)
            terminalEngine.write(data)
            let ptyReply = terminalEngine.takePTYReply()
            scheduleTerminalSnapshot()

            if !ptyReply.isEmpty, let session {
                do {
                    try await session.send(ptyReply)
                } catch {
                    state = .failed(error.localizedDescription)
                }
            }

            if let remotePath = pathUpdates.last?.path ?? terminalEngine.remotePath {
                adoptRemotePath(remotePath)
            }

        case let .terminated(status):
            if let terminalEngine {
                snapshotPresentationTask?.cancel()
                snapshotPresentationTask = nil
                let renderedSnapshot = terminalEngine.snapshot()
                let renderedText = renderedSnapshot.text
                if renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   status != 0
                {
                    transcript = "SSH session ended with status \(status).\n"
                    styledScreen = nil
                    cursor = .hidden
                    scrollbar = .empty
                } else {
                    applyTerminalSnapshot(renderedSnapshot)
                }
            }
            let exitDisposition = SSHSessionExitDisposition(status: status)
            let returnedNormally: Bool
            switch exitDisposition {
            case .returnToHome:
                returnedNormally = true
                state = .disconnected(status)
            case let .retainFailure(status):
                returnedNormally = false
                state = .failed("SSH session ended with status \(status)")
            }
            session = nil
            if returnedNormally {
                terminalEngine = nil
            }
            sftpRefreshTask?.cancel()
            sftpRefreshTask = nil
            commandRefreshTask?.cancel()
            commandRefreshTask = nil
            commandRefreshPending = false
            askPassServer?.stop()
            askPassServer = nil
            clearSessionCredentials()

            guard returnedNormally else {
                return
            }

            let exitHandler = onNormalExit
            onNormalExit = nil
            exitHandler?()
        }
    }

    private func applyTerminalSnapshot(_ snapshot: GhosttyTerminalSnapshot) {
        transcript = snapshot.text
        cursor = snapshot.cursor
        scrollbar = snapshot.scrollbar
        // Publish the cell grid last. Cursor and scrollbar are read by the
        // AppKit host during this single objectWillChange pass.
        styledScreen = snapshot.styledScreen
    }

    private func scheduleTerminalSnapshot() {
        guard snapshotPresentationTask == nil else { return }
        snapshotPresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 16_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, let terminalEngine = self.terminalEngine else {
                return
            }
            self.snapshotPresentationTask = nil
            let snapshot = terminalEngine.snapshot()
            self.applyTerminalSnapshot(snapshot)
            if let remotePath = snapshot.remotePath {
                self.adoptRemotePath(remotePath)
            }
            if !snapshot.ptyReply.isEmpty, let session = self.session {
                try? await session.send(snapshot.ptyReply)
            }
        }
    }

    private func adoptRemotePath(_ path: String) {
        let normalizedPath = normalizeRemotePath(path)
        guard normalizedPath != currentRemotePath else { return }
        currentRemotePath = normalizedPath
        guard commandRefreshPending else { return }
        commandRefreshPending = false
        commandRefreshTask?.cancel()
        commandRefreshTask = nil
        refreshSFTP()
    }

    private func requestSFTPRefreshAfterCommand() {
        commandRefreshPending = true
        commandRefreshTask?.cancel()
        commandRefreshTask = Task { @MainActor [weak self] in
            do {
                // Give the shell time to emit its OSC 7 prompt update so a
                // `cd` refresh lists the new directory rather than the old one.
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.commandRefreshPending = false
            self.commandRefreshTask = nil
            self.refreshSFTP()
        }
    }

    private func makeSFTPClient() throws -> SFTPClient {
        let configuration = try SFTPConnectionConfiguration(
            profile: profile,
            askPassPath: askPassHelperPath(),
            askPassSocketPath: askPassServer?.socketPath,
            sshConfigFileURL: routeConfiguration.fileURL,
            targetAlias: routeConfiguration.targetAlias,
            sshOptions: [
                SFTPSSHOption(name: "StrictHostKeyChecking", value: "accept-new")
            ]
        )
        return SFTPClient(configuration: configuration)
    }

    private func clearSessionCredentials() {
        for key in Array(credentials.keys) {
            credentials[key] = ""
        }
        credentials.removeAll()
    }

    private func authenticationEnvironment() -> [String: String] {
        var environment = [
            // Finder-launched apps normally have no TERM. A concrete terminal
            // type lets remote shells and full-screen programs select the
            // correct capability set.
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor"
        ]

        guard !credentials.isEmpty,
              let helperPath = askPassHelperPath(),
              let socketPath = askPassServer?.socketPath
        else {
            return environment
        }

        environment.merge([
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "osXterm",
            "OSXTERM_ASKPASS_SOCKET": socketPath
        ]) { _, configured in configured }
        return environment
    }

    private func makeAskPassServerIfNeeded() throws -> SessionAskPassServer? {
        guard !credentials.isEmpty else {
            return nil
        }
        let server = try SessionAskPassServer(credentials: credentials)
        return server
    }

    private func askPassHelperPath() -> String? {
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "osXtermAskPass") {
            return bundled
        }

        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("osXtermAskPass")
        return FileManager.default.isExecutableFile(atPath: sibling.path)
            ? sibling.path
            : nil
    }

    private func appendRemotePath(_ component: String) -> String {
        let base = currentRemotePath == "/" ? "" : currentRemotePath
        return normalizeRemotePath(base + "/" + component)
    }

    private func normalizeRemotePath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardized.path
        return normalized.hasPrefix("/") ? normalized : "/" + normalized
    }
}
