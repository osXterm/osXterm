import Foundation

public enum ForwardingKind: String, Codable, CaseIterable, Sendable {
    case local
    case remote
    case dynamic
    case remoteDynamic
    case localUnix
    case remoteUnix
}

public struct ForwardingRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ForwardingKind
    public var bindAddress: String
    public var listenPort: Int?
    public var listenPath: String?
    public var destinationHost: String?
    public var destinationPort: Int?
    public var destinationPath: String?
    public var exposeExternally: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ForwardingKind,
        bindAddress: String = "127.0.0.1",
        listenPort: Int? = nil,
        listenPath: String? = nil,
        destinationHost: String? = nil,
        destinationPort: Int? = nil,
        destinationPath: String? = nil,
        exposeExternally: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.listenPath = listenPath
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.destinationPath = destinationPath
        self.exposeExternally = exposeExternally
        self.enabled = enabled
    }
}

public enum ForwardingValidationError: Error, Equatable, Sendable, LocalizedError {
    case missingListenPort
    case missingListenPath
    case missingDestinationHost
    case missingDestinationPort
    case invalidPort(Int)
    case invalidPath
    case invalidBindAddress
    case externalBindingRequiresOptIn

    public var errorDescription: String? {
        switch self {
        case .missingListenPort: "A listening port is required."
        case .missingListenPath: "A listening socket path is required."
        case .missingDestinationHost: "A destination host is required."
        case .missingDestinationPort: "A destination port is required."
        case let .invalidPort(port): "Invalid forwarding port: \(port)."
        case .invalidPath: "A forwarding socket path is invalid."
        case .invalidBindAddress: "A forwarding bind address is invalid."
        case .externalBindingRequiresOptIn: "External interface binding must be explicitly enabled."
        }
    }
}

public extension ForwardingRule {
    func validate() throws {
        if kind != .localUnix, kind != .remoteUnix,
           !bindAddress.isEmpty,
           bindAddress.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) {
            throw ForwardingValidationError.invalidBindAddress
        }
        if kind != .localUnix, kind != .remoteUnix,
           !exposeExternally, !Self.isLoopback(bindAddress) {
            throw ForwardingValidationError.externalBindingRequiresOptIn
        }

        switch kind {
        case .local, .remote:
            try validateTCPListener()
            guard let destinationHost, !destinationHost.isEmpty else {
                throw ForwardingValidationError.missingDestinationHost
            }
            guard let destinationPort else { throw ForwardingValidationError.missingDestinationPort }
            try Self.validatePort(destinationPort, allowZero: false)
        case .dynamic, .remoteDynamic:
            guard let listenPort else { throw ForwardingValidationError.missingListenPort }
            try Self.validatePort(listenPort, allowZero: kind == .remoteDynamic)
        case .localUnix, .remoteUnix:
            guard let listenPath, Self.isSafeSocketPath(listenPath) else {
                throw ForwardingValidationError.missingListenPath
            }
            if let destinationPath, !destinationPath.isEmpty {
                guard Self.isSafeSocketPath(destinationPath) else {
                    throw ForwardingValidationError.invalidPath
                }
            } else {
                guard let destinationHost, !destinationHost.isEmpty else {
                    throw ForwardingValidationError.missingDestinationHost
                }
                guard let destinationPort else { throw ForwardingValidationError.missingDestinationPort }
                try Self.validatePort(destinationPort, allowZero: false)
            }
        }
    }

    private func validateTCPListener() throws {
        guard let listenPort else { throw ForwardingValidationError.missingListenPort }
        try Self.validatePort(listenPort, allowZero: kind == .remote)
    }

    private static func validatePort(_ port: Int, allowZero: Bool) throws {
        guard (allowZero && port == 0) || (1...65_535).contains(port) else {
            throw ForwardingValidationError.invalidPort(port)
        }
    }

    private static func isSafeSocketPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0") && path.utf8.count < 104
    }

    private static func isLoopback(_ address: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(address.lowercased())
    }
}
