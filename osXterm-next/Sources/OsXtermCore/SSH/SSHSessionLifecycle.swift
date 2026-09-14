import Foundation

public enum SSHConnectionFailure: Equatable, Sendable {
    case userCancelled
    case authentication
    case hostKey
    case transport(message: String)
    case processExit(code: Int32)
}

public struct SSHReconnectPlan: Equatable, Sendable {
    public let attempt: Int
    public let delay: TimeInterval

    public init(attempt: Int, delay: TimeInterval) {
        self.attempt = attempt
        self.delay = delay
    }
}

/// Centralizes reconnect decisions so authentication errors, host-key changes,
/// and user stops never become surprise retry loops.
public enum SSHReconnectPolicy {
    public static func nextPlan(
        after failure: SSHConnectionFailure,
        completedAttempts: Int,
        options: SSHOptions
    ) -> SSHReconnectPlan? {
        guard options.autoReconnect,
              completedAttempts < options.maximumReconnectAttempts
        else {
            return nil
        }
        switch failure {
        case .userCancelled, .authentication, .hostKey:
            return nil
        case .transport, .processExit:
            let attempt = completedAttempts + 1
            let delay = min(30, pow(2, Double(attempt - 1)))
            return SSHReconnectPlan(attempt: attempt, delay: delay)
        }
    }
}

public actor SSHSessionLifecycle {
    private var currentState: SessionState = .idle
    private var reconnectAttempts = 0

    public init() {}

    public func state() -> SessionState {
        currentState
    }

    public func startResolvingRoute() {
        reconnectAttempts = 0
        currentState = .connecting(.resolvingRoute)
    }

    public func preparingAuthentication() {
        currentState = .connecting(.preparingAuthentication)
    }

    public func verifyingHostKey() {
        currentState = .connecting(.verifyingHostKey)
    }

    public func launched() {
        currentState = .connecting(.launching)
    }

    public func waitingForAuthentication() {
        currentState = .authenticating
    }

    public func openingChannels() {
        currentState = .connecting(.openingChannels)
    }

    public func connected() {
        reconnectAttempts = 0
        currentState = .connected
    }

    public func stopping() {
        currentState = .stopping
    }

    public func stopped(exitCode: Int32?) {
        currentState = .stopped(exitCode: exitCode)
    }

    public func failed(
        _ failure: SSHConnectionFailure,
        options: SSHOptions
    ) -> SSHReconnectPlan? {
        if let plan = SSHReconnectPolicy.nextPlan(
            after: failure,
            completedAttempts: reconnectAttempts,
            options: options
        ) {
            reconnectAttempts = plan.attempt
            currentState = .reconnecting(attempt: plan.attempt)
            return plan
        }

        switch failure {
        case let .transport(message):
            currentState = .failed(message: message)
        case let .processExit(code):
            currentState = .stopped(exitCode: code)
        case .userCancelled:
            currentState = .stopped(exitCode: nil)
        case .authentication:
            currentState = .failed(message: "Authentication failed.")
        case .hostKey:
            currentState = .failed(message: "Host key verification failed.")
        }
        return nil
    }
}
