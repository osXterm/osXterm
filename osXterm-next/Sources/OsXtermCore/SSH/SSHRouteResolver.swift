import Foundation

/// A fully expanded connection path. Hops are ordered from the Mac-facing
/// hop to the hop immediately before the target.
public struct ResolvedSSHRoute: Equatable, Sendable {
    public let hops: [ConnectionProfile]
    public let target: ConnectionProfile

    public init(hops: [ConnectionProfile], target: ConnectionProfile) {
        self.hops = hops
        self.target = target
    }

    public var profiles: [ConnectionProfile] {
        hops + [target]
    }

    public var outermostProfile: ConnectionProfile {
        hops.first ?? target
    }

    /// Resolves the one proxy that can be reached from the local Mac.
    ///
    /// A target-level proxy applies to the outermost hop when a route has
    /// jump hosts. This represents `Mac -> proxy -> jump ... -> target`.
    /// Inner-hop proxy settings would need a proxy executable on a remote
    /// machine, so they are rejected rather than silently ignored.
    public func localTransportProxy() throws -> ProxyConfiguration? {
        guard !hops.isEmpty else {
            return target.proxy
        }

        for profile in hops.dropFirst() where profile.proxy != nil {
            throw SSHRouteError.proxyOnInnerHop(profile.id)
        }

        let outerProxy = hops[0].proxy
        let targetProxy = target.proxy
        if let outerProxy, let targetProxy, outerProxy != targetProxy {
            throw SSHRouteError.conflictingLocalProxies(
                outermostProfileID: hops[0].id,
                targetProfileID: target.id
            )
        }
        return targetProxy ?? outerProxy
    }
}

public enum SSHRouteError: Error, Equatable, Sendable {
    case missingProfile(UUID)
    case duplicateProfileID(UUID)
    case duplicateReference(UUID)
    case cyclicReference([UUID])
    case proxyOnInnerHop(UUID)
    case conflictingLocalProxies(outermostProfileID: UUID, targetProfileID: UUID)
}

extension SSHRouteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingProfile(id):
            "The jump profile \(id.uuidString) no longer exists."
        case let .duplicateProfileID(id):
            "More than one profile uses \(id.uuidString)."
        case let .duplicateReference(id):
            "The jump profile \(id.uuidString) appears more than once in the route."
        case let .cyclicReference(ids):
            "The jump route contains a cycle: \(ids.map(\.uuidString).joined(separator: " -> "))."
        case let .proxyOnInnerHop(id):
            "The proxy on inner jump profile \(id.uuidString) cannot be reached from this Mac."
        case let .conflictingLocalProxies(outermostProfileID, targetProfileID):
            "Profiles \(outermostProfileID.uuidString) and \(targetProfileID.uuidString) define different local proxies."
        }
    }
}

/// Resolves saved Jump Host references once before launching OpenSSH. All
/// consumers use the resulting route, which prevents SFTP, tunnels, and the
/// terminal from independently assembling different network paths.
public enum SSHRouteResolver {
    public static func resolve(
        target: ConnectionProfile,
        profiles: [ConnectionProfile]
    ) throws -> ResolvedSSHRoute {
        let profilesByID = try index(profiles, replacing: target)
        var route: [ConnectionProfile] = []
        var emitted = Set<UUID>()
        var stack: [UUID] = [target.id]

        func visit(_ profileID: UUID) throws {
            if let cycleStart = stack.firstIndex(of: profileID) {
                throw SSHRouteError.cyclicReference(Array(stack[cycleStart...]) + [profileID])
            }
            guard !emitted.contains(profileID) else {
                throw SSHRouteError.duplicateReference(profileID)
            }
            guard let profile = profilesByID[profileID] else {
                throw SSHRouteError.missingProfile(profileID)
            }

            stack.append(profileID)
            defer { _ = stack.popLast() }
            for referencedID in profile.jumpProfileIDs {
                try visit(referencedID)
            }
            emitted.insert(profileID)
            route.append(profile)
        }

        for profileID in target.jumpProfileIDs {
            try visit(profileID)
        }

        let resolved = ResolvedSSHRoute(hops: route, target: target)
        _ = try resolved.localTransportProxy()
        return resolved
    }

    public static func resolve(
        targetID: UUID,
        profiles: [ConnectionProfile]
    ) throws -> ResolvedSSHRoute {
        let profilesByID = try index(profiles, replacing: nil)
        guard let target = profilesByID[targetID] else {
            throw SSHRouteError.missingProfile(targetID)
        }
        return try resolve(target: target, profiles: profiles)
    }

    private static func index(
        _ profiles: [ConnectionProfile],
        replacing target: ConnectionProfile?
    ) throws -> [UUID: ConnectionProfile] {
        var result: [UUID: ConnectionProfile] = [:]
        for profile in profiles {
            guard result.updateValue(profile, forKey: profile.id) == nil else {
                throw SSHRouteError.duplicateProfileID(profile.id)
            }
        }
        if let target {
            result[target.id] = target
        }
        return result
    }
}
