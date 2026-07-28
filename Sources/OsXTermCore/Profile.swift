import Foundation

public struct SSHProfile: Codable, Hashable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case authentication
        case encryptedPassword
        case jumpHostProfileIDs
        case jumpHosts
        case proxy
        case agentForwarding
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: SSHAuthentication
    /// AES-GCM ciphertext for an optional password saved with this profile.
    /// The plaintext is never encoded into the profile JSON.
    public var encryptedPassword: String?
    /// References to saved profiles used as ordered Jump Host hops.
    public var jumpHostProfileIDs: [UUID]
    public var proxy: SSHProxy?
    public var agentForwarding: Bool

    /// Legacy values are retained only while a profile is being migrated. They
    /// are never written to the current JSON format and are not used to build
    /// an SSH command after migration.
    @available(*, deprecated, message: "Use jumpHostProfileIDs")
    public var jumpHosts: [SSHJumpHost]
    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authentication: SSHAuthentication = .agent(socketPath: nil),
        encryptedPassword: String? = nil,
        jumpHosts: [SSHJumpHost] = [],
        proxy: SSHProxy? = nil,
        agentForwarding: Bool = false,
        jumpHostProfileIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.encryptedPassword = encryptedPassword
        self.jumpHostProfileIDs = jumpHostProfileIDs
        self.proxy = proxy
        self.agentForwarding = agentForwarding
        self.jumpHosts = jumpHosts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        authentication = try values.decodeIfPresent(SSHAuthentication.self, forKey: .authentication)
            ?? .agent(socketPath: nil)
        encryptedPassword = try values.decodeIfPresent(String.self, forKey: .encryptedPassword)
        jumpHostProfileIDs = try values.decodeIfPresent([UUID].self, forKey: .jumpHostProfileIDs) ?? []
        proxy = try values.decodeIfPresent(SSHProxy.self, forKey: .proxy)
        agentForwarding = try values.decodeIfPresent(Bool.self, forKey: .agentForwarding) ?? false
        jumpHosts = try values.decodeIfPresent([SSHJumpHost].self, forKey: .jumpHosts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(host, forKey: .host)
        try values.encode(port, forKey: .port)
        try values.encode(username, forKey: .username)
        try values.encode(authentication, forKey: .authentication)
        try values.encodeIfPresent(encryptedPassword, forKey: .encryptedPassword)
        try values.encode(jumpHostProfileIDs, forKey: .jumpHostProfileIDs)
        try values.encodeIfPresent(proxy, forKey: .proxy)
        try values.encode(agentForwarding, forKey: .agentForwarding)
    }
}

public enum SSHAuthentication: Hashable, Sendable {
    case agent(socketPath: String?)
    case identityFile(path: String)
    case password
}

extension SSHAuthentication: Codable {
    private enum CodingKeys: String, CodingKey {
        case agent
        case identityFile
        case password
    }

    private enum AgentCodingKeys: String, CodingKey {
        case socketPath
    }

    private enum IdentityFileCodingKeys: String, CodingKey {
        case path
    }

    private struct PasswordMarker: Codable {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.agent) {
            let values = try container.nestedContainer(
                keyedBy: AgentCodingKeys.self,
                forKey: .agent
            )
            self = .agent(socketPath: try values.decodeIfPresent(String.self, forKey: .socketPath))
            return
        }

        if container.contains(.identityFile) {
            let values = try container.nestedContainer(
                keyedBy: IdentityFileCodingKeys.self,
                forKey: .identityFile
            )
            self = .identityFile(path: try values.decode(String.self, forKey: .path))
            return
        }

        if container.contains(.password) {
            // Older profiles may contain an opaque credential reference here.
            // It is intentionally ignored so the saved profile becomes a
            // password profile without reading an external credential store.
            self = .password
            return
        }

        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown SSH authentication type"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .agent(socketPath):
            var values = container.nestedContainer(keyedBy: AgentCodingKeys.self, forKey: .agent)
            try values.encodeIfPresent(socketPath, forKey: .socketPath)

        case let .identityFile(path):
            var values = container.nestedContainer(
                keyedBy: IdentityFileCodingKeys.self,
                forKey: .identityFile
            )
            try values.encode(path, forKey: .path)

        case .password:
            try container.encode(PasswordMarker(), forKey: .password)
        }
    }
}

public struct SSHJumpHost: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var host: String
    public var port: Int
    public var username: String
    public var identityFile: String?

    public init(
        id: UUID = UUID(),
        host: String,
        port: Int = 22,
        username: String,
        identityFile: String? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
    }
}

public enum SSHProxy: Hashable, Sendable {
    case http(host: String, port: Int, username: String?)
    case socks5(host: String, port: Int, username: String?)
}

extension SSHProxy: Codable {
    private enum CodingKeys: String, CodingKey {
        case http
        case socks5
    }

    private enum ValuesCodingKeys: String, CodingKey {
        case host
        case port
        case username
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.http) {
            let values = try container.nestedContainer(
                keyedBy: ValuesCodingKeys.self,
                forKey: .http
            )
            self = .http(
                host: try values.decode(String.self, forKey: .host),
                port: try values.decode(Int.self, forKey: .port),
                username: try values.decodeIfPresent(String.self, forKey: .username)
            )
            return
        }

        if container.contains(.socks5) {
            let values = try container.nestedContainer(
                keyedBy: ValuesCodingKeys.self,
                forKey: .socks5
            )
            self = .socks5(
                host: try values.decode(String.self, forKey: .host),
                port: try values.decode(Int.self, forKey: .port),
                username: try values.decodeIfPresent(String.self, forKey: .username)
            )
            return
        }

        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown SSH proxy type"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .http(host, port, username):
            var values = container.nestedContainer(keyedBy: ValuesCodingKeys.self, forKey: .http)
            try values.encode(host, forKey: .host)
            try values.encode(port, forKey: .port)
            try values.encodeIfPresent(username, forKey: .username)

        case let .socks5(host, port, username):
            var values = container.nestedContainer(keyedBy: ValuesCodingKeys.self, forKey: .socks5)
            try values.encode(host, forKey: .host)
            try values.encode(port, forKey: .port)
            try values.encodeIfPresent(username, forKey: .username)
        }
    }
}

public extension SSHProfile {
    static var blank: SSHProfile {
        SSHProfile(name: "", host: "", username: "")
    }
}
