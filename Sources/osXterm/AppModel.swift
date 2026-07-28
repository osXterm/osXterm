import AppKit
import Foundation
import OsXTermCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    private static let appearanceDefaultsKey = "osXterm.appearance"
    private static let terminalThemeDefaultsKey = "osXterm.terminalThemeID"
    private static let terminalFontSizeDefaultsKey = "osXterm.terminalFontSize"
    private static let terminalFontSizeOverrideDefaultsKey = "osXterm.terminalFontSizeOverride"
    private static let ghosttyConfigurationPathDefaultsKey = "osXterm.ghosttyConfigurationPath"
    private static let legacyProductDefaultsPrefix = "ma" + "Xterm"
    private static func legacyDefaultsKey(_ suffix: String) -> String {
        "\(legacyProductDefaultsPrefix).\(suffix)"
    }
    private static let legacyAppearanceDefaultsKey = legacyDefaultsKey("appearance")
    private static let legacyTerminalThemeIDDefaultsKey = legacyDefaultsKey("terminalThemeID")
    private static let legacyTerminalThemeDefaultsKey = legacyDefaultsKey("terminalTheme")
    private static let legacyTerminalFontSizeDefaultsKey = legacyDefaultsKey("terminalFontSize")
    private static let legacyTerminalFontSizeOverrideDefaultsKey = legacyDefaultsKey("terminalFontSizeOverride")
    private static let legacyGhosttyConfigurationPathDefaultsKey = legacyDefaultsKey("ghosttyConfigurationPath")
    static let terminalFontSizeRange = 10.0 ... 24.0

    @Published private(set) var profiles: [SSHProfile] = []
    @Published var selectedProfileID: SSHProfile.ID?
    @Published private(set) var sessions: [TerminalSessionViewModel] = []
    @Published var selectedSessionID: TerminalSessionViewModel.ID?
    @Published var profileBeingEdited: SSHProfile?
    @Published var isProfileEditorPresented = false
    @Published var isSettingsPresented = false
    @Published private(set) var persistenceError: String?
    @Published private(set) var storageRecoveryNotice: StorageRecoveryNotice?
    @Published private(set) var availableTerminalThemes: [GhosttyTerminalTheme]
    @Published private(set) var ghosttyFontConfiguration: GhosttyFontConfiguration
    @Published var ghosttyConfigurationPath: String {
        didSet {
            UserDefaults.standard.set(
                ghosttyConfigurationPath,
                forKey: Self.ghosttyConfigurationPathDefaultsKey
            )
        }
    }
    @Published var appearancePreference: AppAppearancePreference {
        didSet {
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: Self.appearanceDefaultsKey)
            reloadGhosttyThemes()
        }
    }
    @Published var terminalThemeID: String {
        didSet {
            UserDefaults.standard.set(terminalThemeID, forKey: Self.terminalThemeDefaultsKey)
        }
    }
    @Published var terminalFontSize: Double {
        didSet {
            let clamped = Self.clampedTerminalFontSize(terminalFontSize)
            if clamped != terminalFontSize {
                terminalFontSize = clamped
                return
            }
            UserDefaults.standard.set(terminalFontSize, forKey: Self.terminalFontSizeDefaultsKey)
        }
    }

    private let profileStore: ProfileStore?

    var terminalTheme: GhosttyTerminalTheme {
        availableTerminalThemes.first { $0.id == terminalThemeID }
            ?? availableTerminalThemes.first
            ?? .ghosttyDark
    }

    init() {
        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearanceDefaultsKey)
            ?? UserDefaults.standard.string(forKey: Self.legacyAppearanceDefaultsKey)
        let configuredAppearance = AppAppearancePreference(rawValue: storedAppearance ?? "") ?? .system
        let defaultGhosttyConfigurationPath = GhosttyThemeCatalog.defaultConfigurationPath()
        let configuredGhosttyConfigurationPath = UserDefaults.standard.string(
            forKey: Self.ghosttyConfigurationPathDefaultsKey
        ) ?? UserDefaults.standard.string(
            forKey: Self.legacyGhosttyConfigurationPathDefaultsKey
        ) ?? defaultGhosttyConfigurationPath

        let catalog = GhosttyThemeCatalog.load(
            isDarkAppearance: Self.isDarkAppearance(for: configuredAppearance),
            configurationPath: configuredGhosttyConfigurationPath
        )
        availableTerminalThemes = catalog.themes.map(GhosttyTerminalTheme.init)
        ghosttyFontConfiguration = catalog.fontConfiguration
        ghosttyConfigurationPath = configuredGhosttyConfigurationPath
        let storedTerminalTheme = UserDefaults.standard.string(
            forKey: Self.terminalThemeDefaultsKey
        ) ?? UserDefaults.standard.string(
            forKey: Self.legacyTerminalThemeIDDefaultsKey
        ) ?? UserDefaults.standard.string(forKey: Self.legacyTerminalThemeDefaultsKey)
        let storedTerminalFontSize = UserDefaults.standard.double(
            forKey: Self.terminalFontSizeDefaultsKey
        )
        let legacyStoredTerminalFontSize = UserDefaults.standard.double(
            forKey: Self.legacyTerminalFontSizeDefaultsKey
        )
        terminalThemeID = Self.resolveTerminalThemeID(
            storedValue: storedTerminalTheme,
            catalog: catalog
        )
        let hasFontSizeOverride = UserDefaults.standard.object(
            forKey: Self.terminalFontSizeOverrideDefaultsKey
        ) != nil
            ? UserDefaults.standard.bool(forKey: Self.terminalFontSizeOverrideDefaultsKey)
            : UserDefaults.standard.bool(forKey: Self.legacyTerminalFontSizeOverrideDefaultsKey)
        let followsGhosttyFontSize = !hasFontSizeOverride
        terminalFontSize = Self.clampedTerminalFontSize(
            followsGhosttyFontSize
                ? catalog.fontConfiguration.size ?? 13
                : (storedTerminalFontSize > 0
                    ? storedTerminalFontSize
                    : (legacyStoredTerminalFontSize > 0
                        ? legacyStoredTerminalFontSize
                        : catalog.fontConfiguration.size ?? 13))
        )
        let configuredStore: ProfileStore?
        let initialPersistenceError: String?
        do {
            configuredStore = try ProfileStore()
            initialPersistenceError = nil
        } catch {
            configuredStore = nil
            initialPersistenceError = error.localizedDescription
        }
        profileStore = configuredStore
        appearancePreference = configuredAppearance
        persistenceError = initialPersistenceError
        Task { await loadProfiles() }
    }

    func reloadGhosttyThemes() {
        let catalog = GhosttyThemeCatalog.load(
            isDarkAppearance: Self.isDarkAppearance(for: appearancePreference),
            configurationPath: ghosttyConfigurationPath
        )
        availableTerminalThemes = catalog.themes.map(GhosttyTerminalTheme.init)
        ghosttyFontConfiguration = catalog.fontConfiguration
        if !UserDefaults.standard.bool(forKey: Self.terminalFontSizeOverrideDefaultsKey),
           let configuredSize = catalog.fontConfiguration.size
        {
            terminalFontSize = Self.clampedTerminalFontSize(configuredSize)
        }
        if !availableTerminalThemes.contains(where: { $0.id == terminalThemeID }) {
            terminalThemeID = catalog.configuredThemeID
        }
    }

    /// Marks a size changed from the Settings slider as an intentional osXterm
    /// override. Loading or reloading the Ghostty configuration never sets this
    /// flag, so opening Settings cannot accidentally stop font-size sync.
    func markTerminalFontSizeOverridden() {
        UserDefaults.standard.set(true, forKey: Self.terminalFontSizeOverrideDefaultsKey)
    }

    func openGhosttySettings() {
        let path = ghosttyConfigurationPath.isEmpty
            ? GhosttyThemeCatalog.defaultConfigurationPath()
            : ghosttyConfigurationPath
        guard let configurationURL = GhosttyThemeCatalog.configurationURL(for: path) else {
            return
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configurationURL.path) {
            NSWorkspace.shared.open(configurationURL)
            return
        }

        if let ghosttyApplicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ) {
            NSWorkspace.shared.open(ghosttyApplicationURL)
        } else {
            NSWorkspace.shared.open(configurationURL.deletingLastPathComponent())
        }
    }

    var selectedProfile: SSHProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var selectedSession: TerminalSessionViewModel? {
        sessions.first { $0.id == selectedSessionID }
    }

    func addProfile() {
        profileBeingEdited = .blank
        isProfileEditorPresented = true
    }

    func editSelectedProfile() {
        if let selectedProfile { edit(selectedProfile) }
    }

    func edit(_ profile: SSHProfile) {
        selectedProfileID = profile.id
        profileBeingEdited = profile
        isProfileEditorPresented = true
    }

    func saveProfile(_ profile: SSHProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedProfileID = profile.id
        persistProfiles()
    }

    func deleteSelectedProfile() {
        if let selectedProfile { delete(selectedProfile) }
    }

    func delete(_ profile: SSHProfile) {
        guard !sessions.contains(where: { $0.profile.id == profile.id }) else {
            let alert = NSAlert()
            alert.messageText = "Connection is active"
            alert.informativeText = "Close the active session before deleting this connection."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let references = profiles.filter {
            $0.id != profile.id && $0.jumpHostProfileIDs.contains(profile.id)
        }
        guard references.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Connection is still in use"
            alert.informativeText = references.map(\.name).joined(separator: ", ")
                + " uses this profile as a Jump Host."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Delete connection?"
        confirmation.informativeText = "\(profile.name) will be removed from osXterm."
        confirmation.addButton(withTitle: "Delete")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else {
            return
        }
        profiles.removeAll { $0.id == profile.id }
        selectedProfileID = profiles.first?.id
        persistProfiles()
    }

    func connectSelectedProfile() {
        if let selectedProfile { connect(selectedProfile) }
    }

    func connect(_ profile: SSHProfile, forceNewSession: Bool = false) {
        selectedProfileID = profile.id
        if !forceNewSession {
            if let existingSession = sessions.first(where: {
                $0.profile.id == profile.id && isReusable($0)
            }) {
                selectedSessionID = existingSession.id
                return
            }
        }

        do {
            let route = try SSHRouteResolver.resolve(target: profile, profiles: profiles)
            let configuration = try SSHRouteConfiguration(route: route)
            guard let credentials = collectCredentials(for: route) else {
                configuration.invalidate()
                return
            }
            startSession(route: route, configuration: configuration, credentials: credentials)
        } catch {
            showConnectionError(error)
        }
    }

    func connectNewSession(_ profile: SSHProfile) {
        connect(profile, forceNewSession: true)
    }

    func duplicate(_ profile: SSHProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueCopyName(for: profile.name)
        profiles.append(copy)
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedProfileID = copy.id
        persistProfiles()
    }

    func retrySession(_ session: TerminalSessionViewModel) {
        let profile = session.profile
        removeSession(session)
        Task { await session.disconnect() }
        connect(profile)
    }

    private func startSession(
        route: ResolvedSSHRoute,
        configuration: SSHRouteConfiguration,
        credentials: [String: String]
    ) {
        let session = TerminalSessionViewModel(
            route: route,
            routeConfiguration: configuration,
            credentials: credentials
        )
        session.onNormalExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.removeSession(session)
        }
        sessions.append(session)
        selectedSessionID = session.id
        Task { await session.connect() }
    }

    private func collectCredentials(for route: ResolvedSSHRoute) -> [String: String]? {
        var credentials: [String: String] = [:]
        for profile in route.profiles {
            guard case .password = profile.authentication else { continue }
            let key = credentialKey(for: profile)
            if let encrypted = profile.encryptedPassword,
               let password = try? ProfilePasswordCipher.shared.decrypt(encrypted),
               !password.isEmpty
            {
                credentials[key] = password
                continue
            }

            guard let result = promptForPassword(profile: profile) else {
                return nil
            }
            credentials[key] = result.password
            if result.shouldSave {
                var updated = profile
                do {
                    updated.encryptedPassword = try ProfilePasswordCipher.shared.encrypt(result.password)
                    let previousSelection = selectedProfileID
                    saveProfile(updated)
                    selectedProfileID = previousSelection
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Could not encrypt password"
                    alert.informativeText = "The connection will continue once, but the password was not saved."
                    alert.addButton(withTitle: "Continue")
                    alert.runModal()
                }
            }
        }
        return credentials
    }

    private func promptForPassword(profile: SSHProfile) -> (password: String, shouldSave: Bool)? {
        let target = SSHConnectionTarget.parse(host: profile.host, username: profile.username)
            ?? SSHConnectionTarget(username: profile.username, host: profile.host)
        let alert = NSAlert()
        alert.messageText = "Password required"
        alert.informativeText = "Enter the password for \(target.username)@\(target.host)."
        alert.addButton(withTitle: "Connect once")
        alert.addButton(withTitle: "Save encrypted password")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        while true {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
                return nil
            }
            let password = field.stringValue
            field.stringValue = ""
            if !password.isEmpty {
                return (password, response == .alertSecondButtonReturn)
            }
            alert.informativeText = "A password is required for \(target.username)@\(target.host)."
            NSSound.beep()
        }
    }

    private func credentialKey(for profile: SSHProfile) -> String {
        let target = SSHConnectionTarget.parse(host: profile.host, username: profile.username)
            ?? SSHConnectionTarget(username: profile.username, host: profile.host)
        return "\(target.username)@\(target.host)".lowercased()
    }

    private func showConnectionError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not connect"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func closeSession(_ session: TerminalSessionViewModel) {
        Task { await session.disconnect() }
        removeSession(session)
    }

    func dismissPersistenceNotice() {
        persistenceError = nil
        storageRecoveryNotice = nil
    }

    func recoverStorage() {
        guard let profileStore else {
            persistenceError = "The osXterm configuration directory is unavailable."
            storageRecoveryNotice = nil
            return
        }

        Task {
            do {
                _ = try await profileStore.recoverUnreadableConfiguration()
                try await profileStore.save([])
                profiles = []
                selectedProfileID = nil
                persistenceError = nil
                storageRecoveryNotice = nil
            } catch {
                storageRecoveryNotice = nil
                persistenceError = error.localizedDescription
            }
        }
    }

    private func removeSession(_ session: TerminalSessionViewModel) {
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
    }

    private func isReusable(_ session: TerminalSessionViewModel) -> Bool {
        switch session.state {
        case .idle, .connecting, .connected: true
        case .disconnected, .failed: false
        }
    }

    private func uniqueCopyName(for sourceName: String) -> String {
        let baseName = "\(sourceName) Copy"
        guard profiles.contains(where: { $0.name == baseName }) else { return baseName }
        var index = 2
        while profiles.contains(where: { $0.name == "\(baseName) \(index)" }) { index += 1 }
        return "\(baseName) \(index)"
    }

    private func loadProfiles() async {
        guard let profileStore else {
            persistenceError = "The osXterm configuration directory is unavailable."
            return
        }
        do {
            profiles = try await profileStore.load()
            selectedProfileID = profiles.first?.id
        } catch {
            if case let ProfileStore.StoreError.unreadableFile(url, reason) = error {
                storageRecoveryNotice = StorageRecoveryNotice(
                    path: url.path,
                    reason: reason
                )
            } else {
                persistenceError = error.localizedDescription
            }
        }
    }

    private func persistProfiles() {
        guard let profileStore else {
            persistenceError = "The osXterm configuration directory is unavailable."
            return
        }
        let snapshot = profiles
        Task {
            do {
                try await profileStore.save(snapshot)
                persistenceError = nil
            } catch {
                persistenceError = error.localizedDescription
            }
        }
    }

    private static func resolveTerminalThemeID(
        storedValue: String?,
        catalog: GhosttyThemeCatalogResult
    ) -> String {
        if let storedValue, catalog.themes.contains(where: { $0.id == storedValue }) {
            return storedValue
        }
        if let storedValue {
            let legacyNames: [String: String] = [
                "ghosttyDark": "Ghostty Dark",
                "solarizedDark": "Solarized Dark",
                "solarizedLight": "Solarized Light",
                "dracula": "Dracula"
            ]
            if let legacyName = legacyNames[storedValue],
               let legacyTheme = catalog.themes.first(where: { $0.name == legacyName }) {
                return legacyTheme.id
            }
        }
        return catalog.configuredThemeID
    }

    private static func isDarkAppearance(for preference: AppAppearancePreference) -> Bool {
        switch preference {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private static func clampedTerminalFontSize(_ value: Double) -> Double {
        min(max(value, terminalFontSizeRange.lowerBound), terminalFontSizeRange.upperBound)
    }
}

struct StorageRecoveryNotice: Identifiable {
    let id = UUID()
    let path: String
    let reason: String
}

private extension SSHRouteConfiguration {
    func invalidate() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
