import Foundation

/// The ordered route used by both the interactive SSH session and SFTP.
/// `hops` is ordered from the outermost connection to the innermost one.
public struct ResolvedSSHRoute: Equatable, Sendable {
    public let hops: [SSHProfile]
    public let target: SSHProfile

    public init(hops: [SSHProfile], target: SSHProfile) {
        self.hops = hops
        self.target = target
    }

    public var profiles: [SSHProfile] { hops + [target] }
}

public enum SSHRouteError: Error, Equatable, Sendable {
    case missingProfile(UUID)
    case cyclicReference([UUID])
    case duplicateReference(UUID)
}

extension SSHRouteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingProfile(id):
            "The Jump Host profile " + id.uuidString + " no longer exists."
        case let .cyclicReference(ids):
            "Jump Host profiles contain a cycle: " + ids.map { $0.uuidString }.joined(separator: " -> ") + "."
        case let .duplicateReference(id):
            "Jump Host profile " + id.uuidString + " appears more than once in the route."
        }
    }
}

/// Resolves live profile references and performs the one-time conversion from
/// the old manually entered Jump Host representation.
public enum SSHRouteResolver {
    public static func resolve(
        target: SSHProfile,
        profiles: [SSHProfile]
    ) throws -> ResolvedSSHRoute {
        var byID: [UUID: SSHProfile] = [:]
        for profile in profiles {
            guard byID.updateValue(profile, forKey: profile.id) == nil else {
                throw SSHRouteError.duplicateReference(profile.id)
            }
        }
        byID[target.id] = target
        var path: [UUID] = []
        var emitted = Set<UUID>()
        let hops = try expand(
            profile: target,
            byID: byID,
            path: &path,
            emitted: &emitted
        )
        return ResolvedSSHRoute(hops: hops, target: target)
    }

    public static func resolve(
        targetID: UUID,
        profiles: [SSHProfile]
    ) throws -> ResolvedSSHRoute {
        guard let target = profiles.first(where: { $0.id == targetID }) else {
            throw SSHRouteError.missingProfile(targetID)
        }
        return try resolve(target: target, profiles: profiles)
    }

    /// Converts legacy manual hops into references to existing or generated
    /// saved profiles. Port forwarding values are intentionally discarded.
    public static func migrateLegacyProfiles(_ input: [SSHProfile]) -> [SSHProfile] {
        var profiles = input
        var generatedByEndpoint: [String: UUID] = [:]

        for index in profiles.indices {
            let legacyHops = profiles[index].jumpHosts
            guard !legacyHops.isEmpty else {
                continue
            }

            var references = profiles[index].jumpHostProfileIDs
            for legacyHop in legacyHops {
                let target = SSHConnectionTarget.parse(
                    host: legacyHop.host,
                    username: legacyHop.username
                ) ?? SSHConnectionTarget(username: legacyHop.username, host: legacyHop.host)
                let endpoint = canonicalEndpoint(
                    host: target.host,
                    port: legacyHop.port,
                    username: target.username
                )

                let referenceID: UUID
                if let existing = profiles.first(where: {
                    canonicalEndpoint(
                        host: $0.host,
                        port: $0.port,
                        username: $0.username
                    ) == endpoint && $0.id != profiles[index].id
                }) {
                    referenceID = existing.id
                } else if let generated = generatedByEndpoint[endpoint] {
                    referenceID = generated
                } else {
                    let generatedID = UUID()
                    var generatedName = "Migrated Jump Host \(target.host)"
                    var suffix = 2
                    while profiles.contains(where: { $0.name == generatedName }) {
                        generatedName = "Migrated Jump Host \(target.host) (\(suffix))"
                        suffix += 1
                    }
                    let generatedProfile = SSHProfile(
                        id: generatedID,
                        name: generatedName,
                        host: target.host,
                        port: legacyHop.port,
                        username: target.username,
                        authentication: legacyHop.identityFile.map {
                            .identityFile(path: $0)
                        } ?? .agent(socketPath: nil)
                    )
                    profiles.append(generatedProfile)
                    generatedByEndpoint[endpoint] = generatedID
                    referenceID = generatedID
                }

                if !references.contains(referenceID) {
                    references.append(referenceID)
                }
            }

            profiles[index].jumpHostProfileIDs = references
            profiles[index].jumpHosts = []
        }

        return profiles
    }

    public static func canonicalEndpoint(
        host: String,
        port: Int,
        username: String
    ) -> String {
        let normalizedHost = SSHConnectionTarget.parse(host: host, username: username)?.host
            ?? host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = SSHConnectionTarget.parse(host: host, username: username)?.username
            ?? username.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedUsername.lowercased() + "@" + normalizedHost.lowercased() + ":" + String(port)
    }

    private static func expand(
        profile: SSHProfile,
        byID: [UUID: SSHProfile],
        path: inout [UUID],
        emitted: inout Set<UUID>
    ) throws -> [SSHProfile] {
        if path.contains(profile.id) {
            throw SSHRouteError.cyclicReference(path + [profile.id])
        }
        path.append(profile.id)
        defer { _ = path.popLast() }

        var result: [SSHProfile] = []
        for referenceID in profile.jumpHostProfileIDs {
            guard let referenced = byID[referenceID] else {
                throw SSHRouteError.missingProfile(referenceID)
            }
            guard !emitted.contains(referenceID) else {
                throw SSHRouteError.duplicateReference(referenceID)
            }
            let nested = try expand(
                profile: referenced,
                byID: byID,
                path: &path,
                emitted: &emitted
            )
            result.append(contentsOf: nested)
            guard emitted.insert(referenced.id).inserted else {
                throw SSHRouteError.duplicateReference(referenced.id)
            }
            result.append(referenced)
        }
        return result
    }
}
