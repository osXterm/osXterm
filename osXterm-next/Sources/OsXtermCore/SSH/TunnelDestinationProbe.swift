import Darwin
import Foundation

/// The locally reachable endpoint used to distinguish an SSH forwarding
/// listener from the service behind it. No payload is sent during a probe.
public enum TunnelDestinationProbeTarget: Equatable, Sendable {
    case tcp(host: String, port: Int)
    case unix(path: String)
}

public enum TunnelDestinationProbeFailure: Equatable, Sendable {
    case invalidEndpoint
    case unavailable
    case refused
    case timedOut
}

public enum TunnelDestinationProbeResult: Equatable, Sendable {
    case reachable
    case unreachable(TunnelDestinationProbeFailure)
}

/// Performs a bounded local socket connection on a utility task. This is
/// deliberately a transport probe only: it proves that a listener can open a
/// connection to its configured destination, without sending application data
/// or blocking the SwiftUI executor.
public enum TunnelDestinationProbe {
    public static func target(
        for rule: ForwardingRule,
        assignedPort: Int? = nil
    ) -> TunnelDestinationProbeTarget? {
        switch rule.kind {
        case .local:
            guard let port = assignedPort ?? rule.listenPort,
                  (1 ... 65_535).contains(port)
            else {
                return nil
            }
            return .tcp(host: listenerProbeHost(rule.bindAddress), port: port)

        case .localUnix:
            guard let path = rule.listenPath, SSHInputValidator.socketPath(path) else {
                return nil
            }
            return .unix(path: path)

        case .remote:
            guard let host = rule.destinationHost,
                  SSHInputValidator.host(host),
                  let port = rule.destinationPort,
                  (1 ... 65_535).contains(port)
            else {
                return nil
            }
            return .tcp(host: SSHInputValidator.unbracketedIPv6(host), port: port)

        case .remoteUnix:
            if let path = rule.destinationPath, SSHInputValidator.socketPath(path) {
                return .unix(path: path)
            }
            guard let host = rule.destinationHost,
                  SSHInputValidator.host(host),
                  let port = rule.destinationPort,
                  (1 ... 65_535).contains(port)
            else {
                return nil
            }
            return .tcp(host: SSHInputValidator.unbracketedIPv6(host), port: port)

        case .dynamic, .remoteDynamic:
            return nil
        }
    }

    public static func probe(
        _ target: TunnelDestinationProbeTarget,
        timeoutMilliseconds: Int = 3_000
    ) async -> TunnelDestinationProbeResult {
        let boundedTimeout = min(max(timeoutMilliseconds, 100), 30_000)
        return await Task.detached(priority: .utility) {
            switch target {
            case let .tcp(host, port):
                probeTCP(host: host, port: port, timeoutMilliseconds: boundedTimeout)
            case let .unix(path):
                probeUnix(path: path, timeoutMilliseconds: boundedTimeout)
            }
        }.value
    }

    private static func listenerProbeHost(_ rawAddress: String) -> String {
        let address = SSHInputValidator.unbracketedIPv6(
            rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return switch address.lowercased() {
        case "", "0.0.0.0", "*":
            "127.0.0.1"
        case "::":
            "::1"
        default:
            address
        }
    }

    private static func probeTCP(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) -> TunnelDestinationProbeResult {
        guard SSHInputValidator.host(host), (1 ... 65_535).contains(port) else {
            return .unreachable(.invalidEndpoint)
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var results: UnsafeMutablePointer<addrinfo>?
        let resolution = host.withCString { hostPointer in
            String(port).withCString { servicePointer in
                Darwin.getaddrinfo(hostPointer, servicePointer, &hints, &results)
            }
        }
        guard resolution == 0, let first = results else {
            return .unreachable(.unavailable)
        }
        defer { Darwin.freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var lastFailure: TunnelDestinationProbeFailure = .unavailable
        while let entry = current {
            defer { current = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            let descriptor = Darwin.socket(
                entry.pointee.ai_family,
                entry.pointee.ai_socktype,
                entry.pointee.ai_protocol
            )
            guard descriptor >= 0 else { continue }
            defer { Darwin.close(descriptor) }

            let result = connect(
                descriptor: descriptor,
                address: address,
                length: entry.pointee.ai_addrlen,
                timeoutMilliseconds: timeoutMilliseconds
            )
            if result == .reachable { return result }
            if case let .unreachable(failure) = result {
                lastFailure = failure
            }
        }
        return .unreachable(lastFailure)
    }

    private static func probeUnix(
        path: String,
        timeoutMilliseconds: Int
    ) -> TunnelDestinationProbeResult {
        guard SSHInputValidator.socketPath(path) else {
            return .unreachable(.invalidEndpoint)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .unreachable(.unavailable)
        }
        defer { Darwin.close(descriptor) }

        guard var address = try? SessionCredentialBroker.socketAddress(path: path) else {
            return .unreachable(.invalidEndpoint)
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(
                    descriptor: descriptor,
                    address: $0,
                    length: socklen_t(MemoryLayout<sockaddr_un>.size),
                    timeoutMilliseconds: timeoutMilliseconds
                )
            }
        }
    }

    private static func connect(
        descriptor: Int32,
        address: UnsafePointer<sockaddr>,
        length: socklen_t,
        timeoutMilliseconds: Int
    ) -> TunnelDestinationProbeResult {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else {
            return .unreachable(.unavailable)
        }

        let didConnect = Darwin.connect(descriptor, address, length)
        if didConnect == 0 { return .reachable }
        let connectionError = errno
        guard connectionError == EINPROGRESS || connectionError == EWOULDBLOCK else {
            return .unreachable(failure(for: connectionError))
        }

        var descriptorState = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        let pollResult = Darwin.poll(&descriptorState, 1, Int32(timeoutMilliseconds))
        if pollResult == 0 { return .unreachable(.timedOut) }
        guard pollResult > 0 else { return .unreachable(.unavailable) }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 else {
            return .unreachable(.unavailable)
        }
        return socketError == 0 ? .reachable : .unreachable(failure(for: socketError))
    }

    private static func failure(for error: Int32) -> TunnelDestinationProbeFailure {
        switch error {
        case ECONNREFUSED:
            .refused
        case ETIMEDOUT:
            .timedOut
        default:
            .unavailable
        }
    }
}
