import Foundation

public struct SecretReference: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public var keychainAccount: String {
        "secret-\(id.uuidString.lowercased())"
    }
}

public enum AuthenticationMethod: Codable, Hashable, Sendable {
    case agent(socketPath: String?)
    case privateKey(path: String, passphrase: SecretReference?)
    case password(secret: SecretReference)
    case keyboardInteractive(secret: SecretReference?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case socketPath
        case path
        case passphrase
        case secret
    }

    private enum Kind: String, Codable {
        case agent
        case privateKey
        case password
        case keyboardInteractive
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .agent:
            self = .agent(socketPath: try values.decodeIfPresent(String.self, forKey: .socketPath))
        case .privateKey:
            self = .privateKey(
                path: try values.decode(String.self, forKey: .path),
                passphrase: try values.decodeIfPresent(SecretReference.self, forKey: .passphrase)
            )
        case .password:
            self = .password(secret: try values.decode(SecretReference.self, forKey: .secret))
        case .keyboardInteractive:
            self = .keyboardInteractive(secret: try values.decodeIfPresent(SecretReference.self, forKey: .secret))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .agent(socketPath):
            try values.encode(Kind.agent, forKey: .kind)
            try values.encodeIfPresent(socketPath, forKey: .socketPath)
        case let .privateKey(path, passphrase):
            try values.encode(Kind.privateKey, forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encodeIfPresent(passphrase, forKey: .passphrase)
        case let .password(secret):
            try values.encode(Kind.password, forKey: .kind)
            try values.encode(secret, forKey: .secret)
        case let .keyboardInteractive(secret):
            try values.encode(Kind.keyboardInteractive, forKey: .kind)
            try values.encodeIfPresent(secret, forKey: .secret)
        }
    }
}

public enum ProxyKind: String, Codable, CaseIterable, Sendable {
    case httpConnect
    case socks5
}

public struct ProxyConfiguration: Codable, Hashable, Sendable {
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String?
    public var password: SecretReference?

    public init(
        kind: ProxyKind,
        host: String,
        port: Int,
        username: String? = nil,
        password: SecretReference? = nil
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public struct SSHOptions: Codable, Hashable, Sendable {
    public var connectTimeout: TimeInterval
    public var serverAliveInterval: TimeInterval
    public var serverAliveCountMax: Int
    public var autoReconnect: Bool
    public var maximumReconnectAttempts: Int
    public var forwardAgent: Bool
    public var requestTTY: Bool

    public init(
        connectTimeout: TimeInterval = 15,
        serverAliveInterval: TimeInterval = 30,
        serverAliveCountMax: Int = 3,
        autoReconnect: Bool = false,
        maximumReconnectAttempts: Int = 3,
        forwardAgent: Bool = false,
        requestTTY: Bool = true
    ) {
        self.connectTimeout = connectTimeout
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.autoReconnect = autoReconnect
        self.maximumReconnectAttempts = maximumReconnectAttempts
        self.forwardAgent = forwardAgent
        self.requestTTY = requestTTY
    }

    public static let `default` = SSHOptions()
}

public struct ConnectionFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

public struct ConnectionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var folderID: UUID?
    public var tags: [String]
    public var isFavorite: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: AuthenticationMethod
    public var certificatePath: String?
    public var jumpProfileIDs: [UUID]
    public var proxy: ProxyConfiguration?
    public var options: SSHOptions
    public var forwardingRules: [ForwardingRule]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        folderID: UUID? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        host: String,
        port: Int = 22,
        username: String,
        authentication: AuthenticationMethod = .agent(socketPath: nil),
        certificatePath: String? = nil,
        jumpProfileIDs: [UUID] = [],
        proxy: ProxyConfiguration? = nil,
        options: SSHOptions = .default,
        forwardingRules: [ForwardingRule] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.tags = tags
        self.isFavorite = isFavorite
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.certificatePath = certificatePath
        self.jumpProfileIDs = jumpProfileIDs
        self.proxy = proxy
        self.options = options
        self.forwardingRules = forwardingRules
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProfileDocument: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var folders: [ConnectionFolder]
    public var profiles: [ConnectionProfile]

    public init(
        version: Int = ProfileDocument.currentVersion,
        folders: [ConnectionFolder] = [],
        profiles: [ConnectionProfile] = []
    ) {
        self.version = version
        self.folders = folders
        self.profiles = profiles
    }
}
