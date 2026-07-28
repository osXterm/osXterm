import AppKit
import OsXTermCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selectedRemoteEntry: String?
    @State private var sidebarMode: SidebarMode = .connections
    @State private var isHomePresented = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    fileprivate enum SidebarMode { case connections, files }

    var body: some View {
        VStack(spacing: 0) {
            if !isHomePresented, let session = model.selectedSession {
                SessionHeaderBar(
                    model: model,
                    session: session,
                    onShowHome: {
                        isHomePresented = true
                        sidebarMode = .connections
                        selectedRemoteEntry = nil
                    }
                )
            }

            NavigationSplitView(columnVisibility: $columnVisibility) {
                ContextualSidebar(
                    model: model,
                    mode: $sidebarMode,
                    selectedRemoteEntry: $selectedRemoteEntry,
                    isHomePresented: $isHomePresented
                )
            } detail: {
                terminalWorkspace
            }
            .navigationSplitViewStyle(.prominentDetail)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.addProfile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Connection")
                    .help("New Connection")
                }
                ToolbarItem {
                    Button {
                        model.isSettingsPresented = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
        .environment(\.ghosttyTerminalPalette, model.terminalTheme.palette)
        .environment(\.ghosttyTerminalFontConfiguration, model.ghosttyFontConfiguration)
        .preferredColorScheme(model.appearancePreference.colorScheme)
        .onChange(of: model.selectedSessionID) { _, _ in
            selectedRemoteEntry = nil
            if model.selectedSession == nil {
                isHomePresented = true
                sidebarMode = .connections
            } else if !isHomePresented {
                sidebarMode = model.selectedSession?.state == .connected ? .files : .connections
            }
        }
        .sheet(isPresented: $model.isProfileEditorPresented) {
            if let profile = model.profileBeingEdited {
                ProfileEditorView(profile: profile, profiles: model.profiles) { savedProfile in
                    model.saveProfile(savedProfile)
                    model.isProfileEditorPresented = false
                } onCancel: {
                    model.isProfileEditorPresented = false
                }
            }
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(
                appearancePreference: $model.appearancePreference,
                terminalThemeID: $model.terminalThemeID,
                terminalFontSize: $model.terminalFontSize,
                ghosttyConfigurationPath: $model.ghosttyConfigurationPath,
                terminalThemes: model.availableTerminalThemes,
                onReloadGhosttyConfig: model.reloadGhosttyThemes,
                onOpenGhosttySettings: model.openGhosttySettings,
                onTerminalFontSizeChanged: model.markTerminalFontSizeOverridden
            )
            .environment(\.ghosttyTerminalPalette, model.terminalTheme.palette)
            .environment(\.ghosttyTerminalFontConfiguration, model.ghosttyFontConfiguration)
        }
        .alert(
            "Profile storage error",
            isPresented: Binding(
                get: { model.persistenceError != nil },
                set: { _ in model.dismissPersistenceNotice() }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.persistenceError ?? "")
        }
        .alert(item: Binding(
            get: { model.storageRecoveryNotice },
            set: { _ in model.dismissPersistenceNotice() }
        )) { notice in
            Alert(
                title: Text("Settings need recovery"),
                message: Text(
                    "The settings file at \(notice.path) could not be read.\n\(notice.reason)"
                ),
                primaryButton: .default(Text("Backup and start fresh")) {
                    model.recoverStorage()
                },
                secondaryButton: .cancel {
                    model.dismissPersistenceNotice()
                }
            )
        }
    }

    @ViewBuilder
    private var terminalWorkspace: some View {
        if !isHomePresented, let session = model.selectedSession {
            SessionWorkspaceView(
                model: model,
                session: session,
                onShowHome: {
                    isHomePresented = true
                    sidebarMode = .connections
                    selectedRemoteEntry = nil
                }
            )
        } else {
            VStack(spacing: 0) {
                if !model.sessions.isEmpty {
                    SessionTabBar(
                        model: model,
                        selectedSessionID: nil,
                        onShowHome: {},
                        onSelect: { sessionID in
                            isHomePresented = false
                            model.selectedSessionID = sessionID
                            sidebarMode = model.sessions.first(where: { $0.id == sessionID })?.state == .connected
                                ? .files
                                : .connections
                        }
                    )
                    Divider()
                }

                EmptyTerminalWorkspace(
                    profiles: model.profiles,
                    selectedProfileID: $model.selectedProfileID,
                    connectedProfileIDs: activeProfileIDs,
                    onConnect: { profile in
                        isHomePresented = false
                        model.connectNewSession(profile)
                    },
                    onEdit: model.edit,
                    onDelete: model.delete
                )
            }
        }
    }

    private var activeProfileIDs: Set<SSHProfile.ID> {
        Set(model.sessions.compactMap { session in
            switch session.state {
            case .connecting, .connected: session.profile.id
            case .idle, .disconnected, .failed: nil
            }
        })
    }
}

private struct ContextualSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var mode: ContentView.SidebarMode
    @Binding var selectedRemoteEntry: String?
    @Binding var isHomePresented: Bool

    var body: some View {
        Group {
            if isHomePresented {
                connections
            } else if let session = model.selectedSession {
                SessionAwareSidebar(
                    model: model,
                    session: session,
                    mode: $mode,
                    selectedRemoteEntry: $selectedRemoteEntry,
                    onConnect: connect
                )
                .id(session.id)
            } else {
                connections
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var connections: some View {
        ConnectionSidebar(
            profiles: model.profiles,
            connectedProfileIDs: activeProfileIDs,
            selectedProfileID: $model.selectedProfileID,
            onConnect: connect,
            onEdit: model.edit,
            onDuplicate: model.duplicate,
            onDelete: model.delete
        )
    }

    private func connect(_ profile: SSHProfile) {
        if isHomePresented {
            isHomePresented = false
            model.connectNewSession(profile)
        } else {
            model.connect(profile)
        }
    }

    private var activeProfileIDs: Set<UUID> {
        Set(model.sessions.compactMap { session in
            switch session.state {
            case .connecting, .connected: session.profile.id
            case .idle, .disconnected, .failed: nil
            }
        })
    }
}

private struct SessionAwareSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSessionViewModel
    @Binding var mode: ContentView.SidebarMode
    @Binding var selectedRemoteEntry: String?
    let onConnect: (SSHProfile) -> Void

    var body: some View {
        Group {
            if mode == .files, session.state == .connected {
                SFTPSidebarView(
                    session: session,
                    selectedRemoteEntry: $selectedRemoteEntry
                )
            } else {
                ConnectionSidebar(
                    profiles: model.profiles,
                    connectedProfileIDs: activeProfileIDs,
                    selectedProfileID: $model.selectedProfileID,
                    onConnect: onConnect,
                    onEdit: model.edit,
                    onDuplicate: model.duplicate,
                    onDelete: model.delete
                )
            }
        }
        .onAppear { syncMode(for: session.state) }
        .onChange(of: session.state) { _, state in syncMode(for: state) }
    }

    private func syncMode(for state: TerminalSessionViewModel.ConnectionState) {
        if state == .connected {
            mode = .files
        } else {
            mode = .connections
        }
    }

    private var activeProfileIDs: Set<UUID> {
        Set(model.sessions.compactMap { item in
            switch item.state {
            case .connecting, .connected: item.profile.id
            case .idle, .disconnected, .failed: nil
            }
        })
    }
}

private struct EmptyTerminalWorkspace: View {
    let profiles: [SSHProfile]
    @Binding var selectedProfileID: SSHProfile.ID?
    let connectedProfileIDs: Set<UUID>
    let onConnect: (SSHProfile) -> Void
    let onEdit: (SSHProfile) -> Void
    let onDelete: (SSHProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your connections")
                        .font(.largeTitle.weight(.semibold))
                    Text("Choose a server to open an SSH terminal.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if profiles.isEmpty {
                ContentUnavailableView(
                    "No saved connections",
                    systemImage: "server.rack",
                    description: Text("Use File > New Connection or Command-N to add a server.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                        ForEach(profiles) { profile in
                            HomeProfileCard(
                                profile: profile,
                                isSelected: selectedProfileID == profile.id,
                                isConnected: connectedProfileIDs.contains(profile.id)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .onTapGesture { selectedProfileID = profile.id }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    selectedProfileID = profile.id
                                    onConnect(profile)
                                }
                            )
                            .focusable()
                            .onKeyPress(.return) {
                                guard selectedProfileID == profile.id else { return .ignored }
                                onConnect(profile)
                                return .handled
                            }
                            .contextMenu {
                                Button("Connect") { onConnect(profile) }
                                Button("Edit") { onEdit(profile) }
                                Divider()
                                Button("Delete", role: .destructive) { onDelete(profile) }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

private struct HomeProfileCard: View {
    let profile: SSHProfile
    let isSelected: Bool
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    Text(endpointText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .accessibilityLabel(isConnected ? "Connected" : "Not connected")
            }
            HStack(spacing: 6) {
                CardBadge(title: authenticationTitle)
                if !profile.jumpHostProfileIDs.isEmpty { CardBadge(title: "Jump") }
                if profile.proxy != nil { CardBadge(title: "Proxy") }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor : .secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), \(endpointText), \(authenticationTitle), \(isConnected ? "Connected" : "Not connected")")
        .accessibilityHint("Select once, press Return or double-click to connect")
    }

    private var endpointText: String {
        let target = SSHConnectionTarget.parse(host: profile.host, username: profile.username)
            ?? SSHConnectionTarget(username: profile.username, host: profile.host)
        return "\(target.username)@\(target.host):\(profile.port)"
    }

    private var authenticationTitle: String {
        switch profile.authentication {
        case .agent: "SSH Agent"
        case .identityFile: "Key File"
        case .password: "Password"
        }
    }
}

private struct CardBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct SFTPSidebarView: View {
    @ObservedObject var session: TerminalSessionViewModel
    @Environment(\.ghosttyTerminalFontConfiguration) private var ghosttyFontConfiguration
    @Binding var selectedRemoteEntry: String?
    @State private var isFileDropTargeted = false
    @State private var pathInput = ""
    @FocusState private var isPathFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Files", systemImage: "folder.fill").font(.headline)
                    Text(session.profile.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(12)

            Divider()
            HStack(spacing: 8) {
                Button { session.navigateUp() } label: { Image(systemName: "chevron.up") }
                    .disabled(session.currentRemotePath == "/")
                    .accessibilityLabel("Open parent folder")

                TextField("/remote/path", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(TerminalAppearance.terminalFont(
                        size: 12,
                        configuration: ghosttyFontConfiguration
                    ))
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .layoutPriority(1)
                    .focused($isPathFieldFocused)
                    .onSubmit { navigateToEnteredPath() }
                    .onChange(of: session.currentRemotePath) { _, path in
                        if !isPathFieldFocused {
                            pathInput = path
                        }
                    }
                    .accessibilityLabel("Remote path")

                Button { navigateToEnteredPath() } label: {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open remote path")
                .help("Open remote path")
                if session.isLoadingFiles { ProgressView().controlSize(.small) }
                Button { session.refreshSFTP() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .accessibilityLabel("Refresh files")
            }
            .buttonStyle(.borderless)
            .padding(10)

            Divider()
            List(session.remoteEntries, selection: $selectedRemoteEntry) { entry in
                SFTPEntryRow(
                    entry: entry,
                    onOpen: { session.openEntry(entry.name) },
                    onDownload: { download(entry: entry.name) },
                    fileProvider: { remoteFileProvider(for: entry.name) }
                )
                .tag(entry.name)
            }
            .listStyle(.inset)
            .onDrop(of: [.fileURL], isTargeted: $isFileDropTargeted, perform: receiveFileDrop)
            .overlay { fileListOverlay }

            Divider()
            HStack {
                Button { upload() } label: { Label("Upload", systemImage: "arrow.up.doc") }
                Button { if let selectedRemoteEntry { download(entry: selectedRemoteEntry) } } label: { Label("Download", systemImage: "arrow.down.doc") }
                    .disabled(selectedRemoteEntry == nil || session.remoteEntries.first(where: { $0.name == selectedRemoteEntry })?.isDirectory == true)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        .onAppear { pathInput = session.currentRemotePath }
    }

    private func navigateToEnteredPath() {
        let enteredPath = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredPath.isEmpty else {
            pathInput = session.currentRemotePath
            return
        }

        // This only changes the SFTP listing path. The terminal process keeps
        // its own working directory and receives no shell command here.
        session.navigate(to: enteredPath)
        pathInput = session.currentRemotePath
        isPathFieldFocused = false
    }

    private func receiveFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = SFTPDragAndDropSupport.fileURL(from: item) else { return }
                Task { @MainActor in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    await session.upload(localURL: url)
                }
            }
        }
        return true
    }

    private var dropTargetLabel: some View {
        Label("Drop files to upload", systemImage: "arrow.down.doc")
    }

    @ViewBuilder
    private var fileListOverlay: some View {
        if isFileDropTargeted {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
                .overlay { dropTargetLabel }
                .padding(8)
                .allowsHitTesting(false)
        } else if session.remoteEntries.isEmpty && !session.isLoadingFiles {
            let description = session.fileError ?? "This folder is empty."
            ContentUnavailableView(
                "No remote files",
                systemImage: "folder",
                description: Text(description)
            )
            .allowsHitTesting(false)
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.upload(localURL: url) }
    }

    private func download(entry: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.download(entry: entry, to: url) }
    }

    @MainActor
    private func remoteFileProvider(for entry: String) -> NSItemProvider {
        let remotePath = session.remotePath(for: entry)
        let filename = URL(fileURLWithPath: entry).lastPathComponent.isEmpty ? "remote-download" : URL(fileURLWithPath: entry).lastPathComponent
        return SFTPDragAndDropSupport.remoteFileProvider(suggestedFilename: filename) {
            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osXterm-sftp-exports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let exportURL = exportDirectory.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            await session.download(remotePath: remotePath, to: exportURL)
            guard FileManager.default.isReadableFile(atPath: exportURL.path) else {
                throw NSError(domain: "osXterm.SFTP", code: 1, userInfo: [NSLocalizedDescriptionKey: session.fileError ?? "Unable to download the remote file."])
            }
            return exportURL
        }
    }
}

private struct SFTPEntryRow: View {
    let entry: SFTPRemoteEntry
    let onOpen: () -> Void
    let onDownload: () -> Void
    let fileProvider: () -> NSItemProvider

    var body: some View {
        Label(entry.name, systemImage: entry.isDirectory ? "folder.fill" : "doc.text")
            .font(entry.isDirectory ? .body.weight(.semibold) : .body)
            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if entry.isDirectory { onOpen() }
            }
            .onDrag {
                if entry.isDirectory {
                    return NSItemProvider()
                }
                return fileProvider()
            }
            .contextMenu {
                if entry.isDirectory {
                    Button("Open folder", action: onOpen)
                } else {
                    Button("Download", action: onDownload)
                }
            }
    }
}

private struct SessionHeaderBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSessionViewModel
    let onShowHome: () -> Void

    var body: some View {
        SessionTabBar(
            model: model,
            selectedSessionID: session.id,
            onShowHome: onShowHome,
            onSelect: { model.selectedSessionID = $0 }
        )
        .frame(maxWidth: .infinity)
    }
}

private struct SessionWorkspaceView: View {
    @Environment(\.ghosttyTerminalPalette) private var ghosttyPalette
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSessionViewModel
    let onShowHome: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                GhosttyTerminalView(
                    session: session,
                    fontSize: CGFloat(model.terminalFontSize)
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .clipped()

                connectionOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(ghosttyPalette.background)
    }

    private var endpointText: String {
        let target = SSHConnectionTarget.parse(host: session.profile.host, username: session.profile.username)
            ?? SSHConnectionTarget(username: session.profile.username, host: session.profile.host)
        return "\(target.username)@\(target.host):\(session.profile.port)"
    }

    @ViewBuilder
    private var connectionOverlay: some View {
        switch session.state {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting")
                    .font(.headline)
                Text(endpointText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connecting to \(endpointText)")

        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("Connection failed")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Reconnect") {
                        model.retrySession(session)
                    }
                    .buttonStyle(.glass)
                    Button("Close") {
                        model.closeSession(session)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .contain)

        default:
            EmptyView()
        }
    }
}

private struct SessionTabBar: View {
    @ObservedObject var model: AppModel
    let selectedSessionID: TerminalSessionViewModel.ID?
    let onShowHome: () -> Void
    let onSelect: (TerminalSessionViewModel.ID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onShowHome) {
                Label("Home", systemImage: "house")
                    .font(.callout.weight(selectedSessionID == nil ? .semibold : .regular))
                    .foregroundStyle(selectedSessionID == nil ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        selectedSessionID == nil ? Color.accentColor.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                selectedSessionID == nil ? Color.accentColor : Color.secondary.opacity(0.24),
                                lineWidth: selectedSessionID == nil ? 1.5 : 1
                            )
                    }
            }
            .buttonStyle(.plain)
            .help("Return to connections")
            .accessibilityLabel("Home")
            .accessibilityAddTraits(selectedSessionID == nil ? .isSelected : [])

            Divider()
                .frame(height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sessions) { item in
                        let isSelected = item.id == selectedSessionID
                        Button {
                            onSelect(item.id)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(statusColor(item.state))
                                    .frame(width: 7, height: 7)
                                Text(item.profile.name)
                                    .lineLimit(1)
                                    .font(.callout.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(Color.primary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .frame(minWidth: 118, maxWidth: 220)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        isSelected ? Color.accentColor : Color.secondary.opacity(0.24),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Switch to \(item.profile.name)")
                        .accessibilityLabel("\(item.profile.name), \(item.state.label)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }
}

private func statusColor(_ state: TerminalSessionViewModel.ConnectionState) -> Color {
    switch state {
    case .connected: .green
    case .connecting: .orange
    case .failed, .disconnected: .red
    case .idle: .secondary
    }
}
