import Foundation

public enum TunnelDestinationReachability: Equatable, Sendable {
    case notProbed
    case probing
    case reachable
    case unreachable(message: String)
}

/// Detailed tunnel state retained alongside the presentation-friendly
/// `TunnelStatus`. A listener can be working even while the destination
/// service is down, so those results are deliberately separate.
public struct ManagedTunnelSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let rule: ForwardingRule
    public let status: TunnelStatus
    public let assignedPort: Int?
    public let destination: TunnelDestinationReachability
    public let lastError: String?

    public init(
        rule: ForwardingRule,
        status: TunnelStatus,
        assignedPort: Int? = nil,
        destination: TunnelDestinationReachability = .notProbed,
        lastError: String? = nil
    ) {
        self.id = rule.id
        self.rule = rule
        self.status = status
        self.assignedPort = assignedPort
        self.destination = destination
        self.lastError = lastError
    }
}

public enum TunnelLifecycleError: Error, Equatable, Sendable {
    case unknownRule(UUID)
    case disabledRule(UUID)
    case invalidTransition(ruleID: UUID, status: TunnelStatus)
}

extension TunnelLifecycleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unknownRule(id):
            "Tunnel rule \(id.uuidString) is unknown."
        case let .disabledRule(id):
            "Tunnel rule \(id.uuidString) is disabled."
        case let .invalidTransition(ruleID, status):
            "Tunnel rule \(ruleID.uuidString) cannot transition from \(String(describing: status))."
        }
    }
}

/// An actor-owned state machine for one independent tunnel process. A process
/// runner feeds listener confirmation, stderr, probes, and exit events into
/// this type. It never treats mere process launch as successful forwarding.
public actor TunnelLifecycle {
    private struct Entry: Sendable {
        var rule: ForwardingRule
        var status: TunnelStatus
        var assignedPort: Int?
        var destination: TunnelDestinationReachability
        var lastError: String?

        init(rule: ForwardingRule) {
            self.rule = rule
            self.status = .stopped
            self.assignedPort = nil
            self.destination = .notProbed
            self.lastError = nil
        }

        var snapshot: ManagedTunnelSnapshot {
            ManagedTunnelSnapshot(
                rule: rule,
                status: status,
                assignedPort: assignedPort,
                destination: destination,
                lastError: lastError
            )
        }
    }

    private var entries: [UUID: Entry]

    public init(rules: [ForwardingRule]) {
        entries = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, Entry(rule: $0)) })
    }

    public func snapshots() -> [ManagedTunnelSnapshot] {
        entries.values.map(\.snapshot).sorted { $0.rule.name < $1.rule.name }
    }

    public func snapshot(for ruleID: UUID) throws -> ManagedTunnelSnapshot {
        guard let entry = entries[ruleID] else {
            throw TunnelLifecycleError.unknownRule(ruleID)
        }
        return entry.snapshot
    }

    public func begin(ruleIDs: [UUID]? = nil) throws {
        let selected = ruleIDs ?? entries.keys.sorted { $0.uuidString < $1.uuidString }
        for ruleID in selected {
            var entry = try entry(for: ruleID)
            guard entry.rule.enabled else {
                throw TunnelLifecycleError.disabledRule(ruleID)
            }
            entry.status = .starting
            entry.assignedPort = nil
            entry.destination = .notProbed
            entry.lastError = nil
            entries[ruleID] = entry
        }
    }

    /// Call only after OpenSSH reports or the runner verifies that this rule's
    /// listener was created. For a remote port-0 rule, provide its allocation.
    public func confirmListener(ruleID: UUID, assignedPort: Int? = nil) throws {
        var entry = try entry(for: ruleID)
        guard entry.status == .starting || entry.status == .listening(assignedPort: entry.assignedPort) else {
            throw TunnelLifecycleError.invalidTransition(ruleID: ruleID, status: entry.status)
        }
        let port = assignedPort ?? entry.rule.listenPort
        entry.assignedPort = port
        entry.status = .listening(assignedPort: port)
        entry.destination = .notProbed
        entry.lastError = nil
        entries[ruleID] = entry
    }

    public func beginProbe(ruleID: UUID) throws {
        var entry = try entry(for: ruleID)
        guard case .listening = entry.status else {
            throw TunnelLifecycleError.invalidTransition(ruleID: ruleID, status: entry.status)
        }
        entry.status = .probing
        entry.destination = .probing
        entries[ruleID] = entry
    }

    public func completeProbe(ruleID: UUID, reachable: Bool, errorMessage: String? = nil) throws {
        var entry = try entry(for: ruleID)
        guard case .probing = entry.status else {
            throw TunnelLifecycleError.invalidTransition(ruleID: ruleID, status: entry.status)
        }
        if reachable {
            entry.status = .reachable
            entry.destination = .reachable
            entry.lastError = nil
        } else {
            // The listener remains active. This distinguishes an unavailable
            // destination from a forwarding creation failure.
            entry.status = .listening(assignedPort: entry.assignedPort)
            entry.destination = .unreachable(message: errorMessage ?? "Destination probe failed.")
            entry.lastError = errorMessage
        }
        entries[ruleID] = entry
    }

    public func failListener(ruleID: UUID, message: String) throws {
        var entry = try entry(for: ruleID)
        entry.status = .failed(message: message)
        entry.destination = .notProbed
        entry.lastError = message
        entries[ruleID] = entry
    }

    public func processExited(status: Int32?, wasStoppedByUser: Bool) {
        for ruleID in entries.keys {
            guard var entry = entries[ruleID], entry.status.isActive else { continue }
            if wasStoppedByUser || status == 0 {
                entry.status = .stopped
                entry.destination = .notProbed
                entry.lastError = nil
            } else {
                let message = "OpenSSH tunnel process exited with status \(status.map(String.init) ?? "unknown")."
                entry.status = .failed(message: message)
                entry.destination = .notProbed
                entry.lastError = message
            }
            entries[ruleID] = entry
        }
    }

    public func stop(ruleIDs: [UUID]? = nil) throws {
        let selected = ruleIDs ?? Array(entries.keys)
        for ruleID in selected {
            var entry = try entry(for: ruleID)
            entry.status = .stopped
            entry.assignedPort = nil
            entry.destination = .notProbed
            entry.lastError = nil
            entries[ruleID] = entry
        }
    }

    /// Consumes known OpenSSH verbose output. Callers still need to send an
    /// explicit listener confirmation when OpenSSH does not emit a matching
    /// line for a platform or forwarding mode.
    public func consumeOpenSSHStandardError(_ text: String) {
        for event in OpenSSHTunnelOutputParser.events(in: text, rules: entries.values.map(\.rule)) {
            switch event {
            case let .listenerReady(ruleID, assignedPort):
                try? confirmListener(ruleID: ruleID, assignedPort: assignedPort)
            case let .listenerFailed(ruleID, message):
                try? failListener(ruleID: ruleID, message: message)
            }
        }
    }

    private func entry(for ruleID: UUID) throws -> Entry {
        guard let entry = entries[ruleID] else {
            throw TunnelLifecycleError.unknownRule(ruleID)
        }
        return entry
    }
}

public enum OpenSSHTunnelOutputEvent: Equatable, Sendable {
    case listenerReady(ruleID: UUID, assignedPort: Int?)
    case listenerFailed(ruleID: UUID, message: String)
}

/// Parses only diagnostic evidence emitted by `ssh -o LogLevel=VERBOSE`.
/// It intentionally does not infer destination health from a listener line.
public enum OpenSSHTunnelOutputParser {
    public static func events(
        in standardError: String,
        rules: [ForwardingRule]
    ) -> [OpenSSHTunnelOutputEvent] {
        var events: [OpenSSHTunnelOutputEvent] = []
        for line in standardError.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let lowercased = text.lowercased()
            if lowercased.contains("cannot listen") || lowercased.contains("forwarding failed") {
                for rule in rules where rule.enabled {
                    events.append(.listenerFailed(ruleID: rule.id, message: text))
                }
                continue
            }

            guard lowercased.contains("forwarding listening")
                || lowercased.contains("remote forward success")
                || lowercased.contains("allocated port")
            else {
                continue
            }

            let port = firstPort(in: text)
            let candidates = rules.filter { rule in
                guard rule.enabled else { return false }
                if let port, rule.listenPort == port || rule.listenPort == 0 {
                    return true
                }
                return rule.listenPort == nil && (rule.kind == .localUnix || rule.kind == .remoteUnix)
            }
            for rule in candidates {
                let assignedPort = rule.listenPort == 0 ? port : rule.listenPort
                events.append(.listenerReady(ruleID: rule.id, assignedPort: assignedPort))
            }
        }
        return events
    }

    private static func firstPort(in text: String) -> Int? {
        let scalars = Array(text.unicodeScalars)
        var digits = ""
        for scalar in scalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits.unicodeScalars.append(scalar)
            } else if !digits.isEmpty {
                if let port = Int(digits), (0 ... 65_535).contains(port) {
                    return port
                }
                digits = ""
            }
        }
        if let port = Int(digits), (0 ... 65_535).contains(port) {
            return port
        }
        return nil
    }
}
