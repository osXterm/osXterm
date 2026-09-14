import Foundation
import OsXtermCore

// MARK: - UI-facing values

/// Values consumed by the app shell. The core adapter converts its domain
/// models into these display-safe values, so the views never handle secrets.
struct ProfilePresentation: Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var username: String
    var port: Int
    var folderID: UUID?
    var tags: [String]
    var isFavorite: Bool
    var lastConnectedAt: Date?
    var activeSessionState: SessionPresentationState?
    var jumpHostCount: Int
    var proxySummary: String?

    var endpoint: String {
        "\(username)@\(host):\(port)"
    }

    var isActive: Bool {
        guard let activeSessionState else { return false }
        return activeSessionState.isActive
    }
}

struct FolderPresentation: Identifiable, Hashable {
    let id: UUID
    var name: String
    var profileIDs: [UUID]
}

/// A read-only OpenSSH config import result. It contains no credentials and
/// stays in memory until the user chooses the profiles to persist.
struct SSHConfigImportPreviewPresentation: Identifiable, Hashable {
    let id: UUID
    var sourcePath: String
    var profiles: [SSHConfigImportedProfilePresentation]
    var diagnostics: [SSHConfigImportDiagnosticPresentation]
}

struct SSHConfigImportedProfilePresentation: Identifiable, Hashable {
    let id: UUID
    var alias: String
    var endpoint: String
    var authenticationSummary: String
    var jumpAliases: [String]
    var unsupportedDirectives: [String]
}

struct SSHConfigImportDiagnosticPresentation: Identifiable, Hashable {
    let id: UUID
    var severity: String
    var message: String
    var sourcePath: String
    var line: Int
}

enum SessionPresentationState: Equatable, Hashable {
    case idle
    case connecting
    case authenticating(String)
    case connected
    case reconnecting(attempt: Int)
    case disconnected
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .authenticating, .connected, .reconnecting:
            true
        case .idle, .disconnected, .failed:
            false
        }
    }

    var isInputReady: Bool {
        if case .connected = self { return true }
        return false
    }

    var symbolName: String {
        switch self {
        case .idle, .disconnected:
            "circle"
        case .connecting, .authenticating, .reconnecting:
            "arrow.triangle.2.circlepath"
        case .connected:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}

/// A shell-free process request built by the core service and launched by
/// SwiftTerm's `LocalProcess` PTY in the AppKit terminal bridge. Environment
/// entries may include helper socket paths, but never a credential value.
struct TerminalProcessLaunchPresentation: Hashable {
    let launchID: UUID
    var executable: String
    var arguments: [String]
    var environment: [String]
    var currentDirectory: String?
}

/// A one-way, in-memory write request from the workspace service to the PTY.
/// It is used only after a user explicitly runs a snippet or enables
/// broadcast input. The sequence prevents SwiftUI refreshes from replaying a
/// command, and this value is never persisted with a workspace.
struct TerminalInputPresentation: Hashable {
    var sequence: UInt64
    var data: Data
}

enum TerminalFindDirection: Hashable {
    case next
    case previous
    case clear
}

/// A one-way, in-memory terminal-buffer search request. The sequence makes a
/// repeated navigation action observable to the AppKit adapter without
/// persisting a query or terminal contents.
struct TerminalFindPresentation: Hashable {
    var sequence: UInt64
    var query: String
    var direction: TerminalFindDirection
    var isCaseSensitive: Bool
    var usesRegularExpression: Bool
    var matchesWholeWord: Bool
}

struct TerminalFindResultPresentation: Hashable {
    var sequence: UInt64
    var didFindMatch: Bool
    var currentMatchIndex: Int
    var totalMatches: Int
}

struct TerminalSessionPresentation: Identifiable, Hashable {
    let id: UUID
    var title: String
    var profileID: UUID?
    var isLocal: Bool
    var state: SessionPresentationState
    var launch: TerminalProcessLaunchPresentation?
    var currentDirectory: String?
    var activeProcessDescription: String?
    var supportsFileTransfer: Bool
    var isReadOnly: Bool
    var isSessionLoggingEnabled: Bool
    var hasSessionLog: Bool
    var pendingInput: TerminalInputPresentation?

    var accessibilityState: String {
        switch state {
        case .idle:
            AppText.string("Not connected", korean: "연결되지 않음")
        case .connecting:
            AppText.string("Connecting", korean: "연결 중")
        case let .authenticating(step):
            AppText.string("Authenticating: \(step)", korean: "인증 중: \(step)")
        case .connected:
            AppText.string("Connected", korean: "연결됨")
        case let .reconnecting(attempt):
            AppText.string("Reconnecting, attempt \(attempt)", korean: "재연결 중, \(attempt)회 시도")
        case .disconnected:
            AppText.string("Disconnected", korean: "연결 끊김")
        case let .failed(message):
            AppText.string("Failed: \(message)", korean: "실패: \(message)")
        }
    }
}

enum WorkspaceLayoutPresentation: String, CaseIterable, Identifiable {
    case single
    case horizontalSplit
    case verticalSplit

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .single: "rectangle"
        case .horizontalSplit: "rectangle.split.2x1"
        case .verticalSplit: "rectangle.split.1x2"
        }
    }
}

enum TransferPhasePresentation: Hashable {
    case queued
    case preparing
    case transferring
    case paused
    case completed
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .preparing, .transferring, .paused:
            false
        }
    }
}

struct TransferPresentation: Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var sourceDescription: String
    var destinationDescription: String
    var bytesTransferred: Int64
    var totalBytes: Int64?
    var phase: TransferPhasePresentation
    var sessionID: UUID?

    var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }
}

enum RemoteFileKindPresentation: Hashable {
    case file
    case directory
    case symbolicLink(target: String?)
}

struct RemoteFilePresentation: Identifiable, Hashable {
    let id: String
    var name: String
    var absolutePath: String
    var kind: RemoteFileKindPresentation
    var size: Int64?
    var modifiedAt: Date?
    var permissions: String?

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }
}

/// A deliberately explicit local working copy. Saving an editor document does
/// not upload it. The user must select "Save to Remote" for that operation.
struct RemoteEditPresentation: Identifiable, Hashable {
    let id: UUID
    var sessionID: UUID
    var remotePath: String
    var localURL: URL

    var displayName: String { localURL.lastPathComponent }
}

enum TunnelPhasePresentation: Hashable {
    case stopped
    case starting
    case listening
    case failed(String)
    case stopping
}

enum TunnelDirectionPresentation: String, CaseIterable, Identifiable {
    case local
    case remote
    case dynamic
    case remoteDynamic
    case localSocket
    case remoteSocket

    var id: Self { self }
}

struct TunnelPresentation: Identifiable, Hashable {
    let id: UUID
    var name: String
    var direction: TunnelDirectionPresentation
    var bindAddress: String
    var listeningEndpoint: String?
    var destination: String?
    var destinationReachability: TunnelDestinationReachability
    var phase: TunnelPhasePresentation
    var sessionID: UUID?
    var isIndependent: Bool
}

struct SnippetVariablePresentation: Identifiable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    var isSecret: Bool
}

struct SnippetPresentation: Identifiable, Hashable {
    let id: UUID
    var title: String
    var summary: String
    var commandsText: String
    var variables: [SnippetVariablePresentation]

    var requiresInput: Bool { !variables.isEmpty }
}

enum AuthenticationChallengeKindPresentation: Equatable {
    case credential
    case hostKeyNew(fingerprint: String)
    case hostKeyChanged(fingerprint: String)
}

struct AuthenticationChallengePresentation: Identifiable, Equatable {
    let id: UUID
    var sessionID: UUID
    var prompt: String
    var isSecure: Bool
    var attemptDescription: String?
    var kind: AuthenticationChallengeKindPresentation

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        prompt: String,
        isSecure: Bool,
        attemptDescription: String? = nil,
        kind: AuthenticationChallengeKindPresentation = .credential
    ) {
        self.id = id
        self.sessionID = sessionID
        self.prompt = prompt
        self.isSecure = isSecure
        self.attemptDescription = attemptDescription
        self.kind = kind
    }
}

struct AppSettingsPresentation: Equatable {
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: Self { self }
    }

    var appearance: Appearance
    var terminalFontName: String
    var terminalFontSize: Double
    var terminalLineSpacing: Double
    var terminalThemeName: String
    var allowRemoteClipboard: Bool
    var keepTunnelsRunningWhenWindowCloses: Bool
    var sessionLoggingEnabled: Bool

    static let `default` = AppSettingsPresentation(
        appearance: .system,
        terminalFontName: TerminalFont.preferredDefault.rawValue,
        terminalFontSize: 13,
        terminalLineSpacing: 1,
        terminalThemeName: "System",
        allowRemoteClipboard: false,
        keepTunnelsRunningWhenWindowCloses: true,
        sessionLoggingEnabled: false
    )
}

/// The terminal color themes that osXterm can render directly through the
/// SwiftTerm adapter. The persisted setting remains a string so existing
/// workspace documents can be read without a schema migration.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case midnight = "Midnight"
    case solarizedDark = "Solarized Dark"
    case solarizedLight = "Solarized Light"
    case dracula = "Dracula"
    case nord = "Nord"
    case gruvboxDark = "Gruvbox Dark"
    case gruvboxLight = "Gruvbox Light"
    case catppuccinMocha = "Catppuccin Mocha"
    case catppuccinLatte = "Catppuccin Latte"
    case tokyoNight = "Tokyo Night"
    case tokyoNightStorm = "Tokyo Night Storm"
    case monokaiPro = "Monokai Pro"
    case oneDark = "One Dark"
    case githubDark = "GitHub Dark"
    case githubLight = "GitHub Light"
    case rosePine = "Rosé Pine"
    case everforestDark = "Everforest Dark"
    case ayuMirage = "Ayu Mirage"
    case kanagawaWave = "Kanagawa Wave"

    var id: String { rawValue }

    init(persistedName: String) {
        let normalized = persistedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let theme = Self.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
            self = theme
            return
        }
        switch normalized {
        case "midnight":
            self = .midnight
        case "solarized dark", "solarized-dark", "solarizeddark":
            self = .solarizedDark
        case "solarized light", "solarized-light", "solarizedlight":
            self = .solarizedLight
        case "catppuccin-mocha", "catppuccinmocha":
            self = .catppuccinMocha
        case "catppuccin-latte", "catppuccinlatte":
            self = .catppuccinLatte
        case "tokyo-night", "tokyonight":
            self = .tokyoNight
        case "tokyo-night-storm", "tokyonightstorm":
            self = .tokyoNightStorm
        case "rose pine", "rose-pine", "rosepine":
            self = .rosePine
        case "everforest", "everforest-dark":
            self = .everforestDark
        case "ayu", "ayu-mirage":
            self = .ayuMirage
        case "kanagawa", "kanagawa-wave":
            self = .kanagawaWave
        default:
            self = .system
        }
    }

    var displayName: String {
        switch self {
        case .system:
            AppText.string("System", korean: "시스템")
        case .midnight:
            AppText.string("Midnight", korean: "미드나이트")
        case .solarizedDark:
            AppText.string("Solarized Dark", korean: "Solarized 다크")
        case .solarizedLight:
            AppText.string("Solarized Light", korean: "Solarized 라이트")
        default:
            rawValue
        }
    }
}

/// Curated fonts that ship inside osXterm. Their raw values are the verified
/// Core Text PostScript names, so saved settings do not depend on the user's
/// installed font collection.
enum TerminalFont: String, CaseIterable, Identifiable {
    case d2Coding = "D2Coding"
    case jetBrainsMono = "JetBrainsMono-Regular"
    case firaCode = "FiraCode-Regular"
    case hack = "Hack-Regular"

    static let preferredDefault = TerminalFont.d2Coding

    var id: String { rawValue }
    var regularPostScriptName: String { rawValue }

    var boldPostScriptName: String {
        switch self {
        case .d2Coding: "D2CodingBold"
        case .jetBrainsMono: "JetBrainsMono-Bold"
        case .firaCode: "FiraCode-Bold"
        case .hack: "Hack-Bold"
        }
    }

    var resourceFileNames: [String] {
        switch self {
        case .d2Coding: ["D2Coding-Regular.ttf", "D2Coding-Bold.ttf"]
        case .jetBrainsMono: ["JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf"]
        case .firaCode: ["FiraCode-Regular.ttf", "FiraCode-Bold.ttf"]
        case .hack: ["Hack-Regular.ttf", "Hack-Bold.ttf"]
        }
    }

    init(persistedName: String) {
        switch persistedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "d2coding", "d2 coding", "sf mono", "sfmono":
            self = .d2Coding
        case "jetbrainsmono", "jetbrains mono", "jetbrainsmono-regular":
            self = .jetBrainsMono
        case "firacode", "fira code", "firacode-regular":
            self = .firaCode
        case "hack", "hack-regular":
            self = .hack
        default:
            self = .preferredDefault
        }
    }

    var displayName: String {
        switch self {
        case .d2Coding:
            AppText.string("D2 Coding", korean: "D2 Coding 한글")
        case .jetBrainsMono:
            "JetBrains Mono"
        case .firaCode:
            "Fira Code"
        case .hack:
            "Hack"
        }
    }
}

struct AppWorkspaceSnapshot: Equatable {
    var profiles: [ProfilePresentation]
    var folders: [FolderPresentation]
    var sessions: [TerminalSessionPresentation]
    var selectedSessionID: UUID?
    var paneSessionIDs: [UUID]
    var layout: WorkspaceLayoutPresentation
    var transfers: [TransferPresentation]
    var remoteDirectoryPath: String?
    var remoteFiles: [RemoteFilePresentation]
    var remoteEdits: [RemoteEditPresentation]
    var tunnels: [TunnelPresentation]
    var snippets: [SnippetPresentation]
    var broadcastTargetSessionIDs: Set<UUID>
    var settings: AppSettingsPresentation
    var authenticationChallenge: AuthenticationChallengePresentation?

    static let empty = AppWorkspaceSnapshot(
        profiles: [],
        folders: [],
        sessions: [],
        selectedSessionID: nil,
        paneSessionIDs: [],
        layout: .single,
        transfers: [],
        remoteDirectoryPath: nil,
        remoteFiles: [],
        remoteEdits: [],
        tunnels: [],
        snippets: [],
        broadcastTargetSessionIDs: [],
        settings: .default,
        authenticationChallenge: nil
    )
}

enum AuthenticationMethodPresentation: String, CaseIterable, Identifiable {
    case sshAgent
    case privateKey
    case password
    case keyboardInteractive
    case certificate

    var id: Self { self }
}

enum ProxyKindPresentation: String, CaseIterable, Identifiable {
    case none
    case httpConnect
    case socks5

    var id: Self { self }
}

struct ForwardingDraftPresentation: Identifiable, Hashable {
    let id: UUID
    var name: String
    var direction: TunnelDirectionPresentation
    var bindAddress: String
    var source: String
    var destination: String
    var startIndependently: Bool

    static func blank() -> ForwardingDraftPresentation {
        ForwardingDraftPresentation(
            id: UUID(),
            name: "",
            direction: .local,
            bindAddress: "127.0.0.1",
            source: "",
            destination: "",
            startIndependently: false
        )
    }
}

struct ProfileDraftPresentation: Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: String
    var username: String
    var authenticationMethod: AuthenticationMethodPresentation
    var identityFilePath: String
    var certificateFilePath: String
    var agentSocketPath: String
    var jumpProfileIDs: [UUID]
    var proxyKind: ProxyKindPresentation
    var proxyHost: String
    var proxyPort: String
    var proxyUsername: String
    var agentForwardingEnabled: Bool
    var connectTimeoutSeconds: String
    var keepaliveSeconds: String
    var autoReconnectEnabled: Bool
    var forwardingRules: [ForwardingDraftPresentation]
    var tags: [String]
    var folderID: UUID?
    var isFavorite: Bool

    static func blank() -> ProfileDraftPresentation {
        ProfileDraftPresentation(
            id: UUID(),
            name: "",
            host: "",
            port: "22",
            username: "",
            authenticationMethod: .sshAgent,
            identityFilePath: "",
            certificateFilePath: "",
            agentSocketPath: "",
            jumpProfileIDs: [],
            proxyKind: .none,
            proxyHost: "",
            proxyPort: "",
            proxyUsername: "",
            agentForwardingEnabled: false,
            connectTimeoutSeconds: "15",
            keepaliveSeconds: "30",
            autoReconnectEnabled: false,
            forwardingRules: [],
            tags: [],
            folderID: nil,
            isFavorite: false
        )
    }
}

/// Ephemeral credentials accepted by a profile-save request. These values must
/// be consumed by the core adapter and never returned in a snapshot.
struct ProfileEditorSecrets {
    var password: String
    var privateKeyPassphrase: String
    var proxyPassword: String

    static let empty = ProfileEditorSecrets(password: "", privateKeyPassphrase: "", proxyPassword: "")
}

struct ProfileEditorSubmission {
    var draft: ProfileDraftPresentation
    var secrets: ProfileEditorSecrets
}

enum ProfileEditorMode: Equatable {
    case create
    case edit
}

struct ProfileEditorRequest: Identifiable {
    let id = UUID()
    var mode: ProfileEditorMode
    var draft: ProfileDraftPresentation
}

struct TunnelEditorRequest: Identifiable {
    let id = UUID()
    var existing: ForwardingDraftPresentation?
    var sessionID: UUID?
}

enum InspectorSection: String, CaseIterable, Identifiable {
    case transfers
    case tunnels
    case connection

    var id: Self { self }
}

enum AppSidebarSelection: Hashable {
    case profile(UUID)
    case folder(UUID)
    case favorite
    case recent
}
