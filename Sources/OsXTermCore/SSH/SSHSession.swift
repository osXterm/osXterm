import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum SSHSessionOutput: Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case terminated(status: Int32)
}

public enum SSHSessionState: Equatable, Sendable {
    case idle
    case running(processIdentifier: Int32)
    case exited(status: Int32)
    case failed(message: String)
}

public enum SSHSessionExitDisposition: Equatable, Sendable {
    case returnToHome
    case retainFailure(status: Int32)

    public init(status: Int32) {
        self = status == 0 ? .returnToHome : .retainFailure(status: status)
    }
}

public enum SSHSessionError: Error, Equatable, Sendable {
    case alreadyStarted
    case notRunning
    case standardInputClosed
    case askPassHelperRequired
    case invalidAskPassPath
    case askPassCredentialUnavailable
    case pseudoTerminalUnavailable(message: String)
    case launchFailed(message: String)
}

extension SSHSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "This SSH session has already been started."
        case .notRunning:
            "The SSH session is not running."
        case .standardInputClosed:
            "The SSH session's standard input is closed."
        case .askPassHelperRequired:
            "Password or passphrase authentication requires an SSH_ASKPASS helper."
        case .invalidAskPassPath:
            "The SSH_ASKPASS helper path is empty or contains a null byte."
        case .askPassCredentialUnavailable:
            "A password session requires an active in-memory AskPass credential."
        case let .pseudoTerminalUnavailable(message):
            "Unable to create a local terminal: \(message)"
        case let .launchFailed(message):
            "Unable to launch ssh: \(message)"
        }
    }
}

public struct SSHSessionConfiguration: Sendable {
    /// Additional environment entries such as SSH_ASKPASS and its socket path.
    ///
    /// A credential value must never be stored in this dictionary. Password
    /// sessions use a local Unix-domain socket owned by the active session.
    public var environmentOverrides: [String: String]
    public var inheritParentEnvironment: Bool
    public var currentDirectoryURL: URL?
    /// Connect stdin, stdout, and stderr to one local pseudo-terminal.
    /// Interactive SSH uses this mode to preserve terminal semantics.
    public var usesPseudoTerminal: Bool
    public var terminalColumns: Int
    public var terminalRows: Int

    public init(
        environmentOverrides: [String: String] = [:],
        inheritParentEnvironment: Bool = true,
        currentDirectoryURL: URL? = nil,
        usesPseudoTerminal: Bool = false,
        terminalColumns: Int = 120,
        terminalRows: Int = 36
    ) {
        self.environmentOverrides = environmentOverrides
        self.inheritParentEnvironment = inheritParentEnvironment
        self.currentDirectoryURL = currentDirectoryURL
        self.usesPseudoTerminal = usesPseudoTerminal
        self.terminalColumns = max(1, terminalColumns)
        self.terminalRows = max(1, terminalRows)
    }
}

/// Owns one system `ssh` process and exposes its byte streams asynchronously.
///
/// Each instance is single-use. Create a new session after it exits.
public actor SSHSession {
    public nonisolated let output: AsyncStream<SSHSessionOutput>

    private let command: SSHCommand
    private let configuration: SSHSessionConfiguration
    private let askPassPath: String?
    private let outputContinuation: AsyncStream<SSHSessionOutput>.Continuation

    private var process: Process?
    private var standardInput: FileHandle?
    private var pseudoTerminal: PseudoTerminal?
    private var stateValue: SSHSessionState = .idle
    private var terminationStatus: Int32?
    private var standardOutputClosed = false
    private var standardErrorClosed = false
    private var waiters: [CheckedContinuation<Int32, any Error>] = []

    public init(
        command: SSHCommand,
        askPassPath: String? = nil,
        configuration: SSHSessionConfiguration = SSHSessionConfiguration()
    ) {
        self.command = command
        self.askPassPath = askPassPath
        self.configuration = configuration

        let stream = AsyncStream.makeStream(
            of: SSHSessionOutput.self,
            bufferingPolicy: .unbounded
        )
        output = stream.stream
        outputContinuation = stream.continuation
    }

    deinit {
        outputContinuation.finish()
        try? standardInput?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    public var state: SSHSessionState {
        stateValue
    }

    public func start() throws {
        guard stateValue == .idle else {
            throw SSHSessionError.alreadyStarted
        }

        let process = Process()
        let inputPipe = configuration.usesPseudoTerminal ? nil : Pipe()
        let outputPipe = configuration.usesPseudoTerminal ? nil : Pipe()
        let errorPipe = configuration.usesPseudoTerminal ? nil : Pipe()
        let terminal = configuration.usesPseudoTerminal
            ? try PseudoTerminal(
                columns: configuration.terminalColumns,
                rows: configuration.terminalRows
            )
            : nil

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        if let terminal {
            process.standardInput = terminal.standardInput
            process.standardOutput = terminal.standardOutput
            process.standardError = terminal.standardError
        } else {
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
        }
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.environment = try resolvedEnvironment()

        let continuation = outputContinuation
        let outputHandle = terminal?.master ?? outputPipe?.fileHandleForReading
        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task {
                    await self?.didCloseOutputChannel(isStandardError: false)
                }
                return
            }
            continuation.yield(.standardOutput(data))
        }

        if let errorPipe {
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    Task {
                        await self?.didCloseOutputChannel(isStandardError: true)
                    }
                    return
                }
                continuation.yield(.standardError(data))
            }
        } else {
            // A pseudo-terminal multiplexes stdout and stderr onto its master
            // descriptor, so only the one read channel needs to close.
            standardErrorClosed = true
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.didTerminate(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            outputHandle?.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            try? inputPipe?.fileHandleForWriting.close()
            try? outputPipe?.fileHandleForReading.close()
            try? errorPipe?.fileHandleForReading.close()
            terminal?.close()

            let message = String(describing: error)
            stateValue = .failed(message: message)
            outputContinuation.finish()
            throw SSHSessionError.launchFailed(message: message)
        }

        self.process = process
        if let terminal {
            terminal.closeChildHandles()
            pseudoTerminal = terminal
            standardInput = terminal.master
        } else {
            standardInput = inputPipe?.fileHandleForWriting
        }
        stateValue = .running(processIdentifier: process.processIdentifier)
    }

    public func send(_ data: Data) throws {
        guard case .running = stateValue else {
            throw SSHSessionError.notRunning
        }
        guard let standardInput else {
            throw SSHSessionError.standardInputClosed
        }

        do {
            try standardInput.write(contentsOf: data)
        } catch {
            self.standardInput = nil
            throw SSHSessionError.standardInputClosed
        }
    }

    public func send(_ text: String, encoding: String.Encoding = .utf8) throws {
        guard let data = text.data(using: encoding) else {
            throw SSHSessionError.standardInputClosed
        }
        try send(data)
    }

    public func closeStandardInput() throws {
        guard case .running = stateValue else {
            throw SSHSessionError.notRunning
        }
        guard let standardInput else {
            return
        }

        try standardInput.close()
        self.standardInput = nil
    }

    public func interrupt() throws {
        guard case .running = stateValue, let process else {
            throw SSHSessionError.notRunning
        }
        process.interrupt()
    }

    /// Updates the remote terminal geometry when this session was launched with
    /// a local pseudo-terminal. Pipe-backed command sessions have no geometry.
    public func resizeTerminal(columns: Int, rows: Int) throws {
        guard case .running = stateValue else {
            throw SSHSessionError.notRunning
        }
        guard let pseudoTerminal else {
            return
        }

        try pseudoTerminal.resize(columns: columns, rows: rows)

        #if canImport(Darwin)
        if let process {
            _ = Darwin.kill(process.processIdentifier, SIGWINCH)
        }
        #endif
    }

    public func terminate() throws {
        guard case .running = stateValue, let process else {
            throw SSHSessionError.notRunning
        }
        process.terminate()
    }

    public func waitUntilExit() async throws -> Int32 {
        switch stateValue {
        case let .exited(status):
            return status
        case let .failed(message):
            throw SSHSessionError.launchFailed(message: message)
        case .idle:
            throw SSHSessionError.notRunning
        case .running:
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private func resolvedEnvironment() throws -> [String: String] {
        var environment = configuration.inheritParentEnvironment
            ? ProcessInfo.processInfo.environment
            : [:]

        environment.merge(configuration.environmentOverrides) { _, configured in configured }
        environment.merge(command.environmentOverrides) { _, commandValue in commandValue }

        if command.requiresAskPass {
            guard let resolvedAskPassPath = askPassPath
                ?? configuration.environmentOverrides["SSH_ASKPASS"]
            else {
                throw SSHSessionError.askPassHelperRequired
            }
            guard
                !resolvedAskPassPath.isEmpty,
                !resolvedAskPassPath.contains("\0")
            else {
                throw SSHSessionError.invalidAskPassPath
            }
            guard let socketPath = environment["OSXTERM_ASKPASS_SOCKET"],
                  !socketPath.isEmpty,
                  !socketPath.contains("\0")
            else {
                throw SSHSessionError.askPassCredentialUnavailable
            }

            environment["SSH_ASKPASS"] = resolvedAskPassPath
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "osXterm"
        }

        return environment
    }

    private func didTerminate(status: Int32) {
        terminationStatus = status
        stateValue = .exited(status: status)
        standardInput = nil

        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: status) }

        finishOutputIfReady()
    }

    private func didCloseOutputChannel(isStandardError: Bool) {
        if isStandardError {
            standardErrorClosed = true
        } else {
            standardOutputClosed = true
        }
        finishOutputIfReady()
    }

    private func finishOutputIfReady() {
        guard
            let terminationStatus,
            standardOutputClosed,
            standardErrorClosed
        else {
            return
        }

        outputContinuation.yield(.terminated(status: terminationStatus))
        outputContinuation.finish()
        process = nil
        pseudoTerminal = nil
    }
}

private final class PseudoTerminal {
    let master: FileHandle
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    init(columns: Int, rows: Int) throws {
        #if canImport(Darwin)
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
            throw SSHSessionError.pseudoTerminalUnavailable(
                message: String(cString: strerror(errno))
            )
        }

        defer {
            Darwin.close(slaveDescriptor)
        }

        let inputDescriptor = Darwin.dup(slaveDescriptor)
        let outputDescriptor = Darwin.dup(slaveDescriptor)
        let errorDescriptor = Darwin.dup(slaveDescriptor)
        guard inputDescriptor >= 0, outputDescriptor >= 0, errorDescriptor >= 0 else {
            if inputDescriptor >= 0 { Darwin.close(inputDescriptor) }
            if outputDescriptor >= 0 { Darwin.close(outputDescriptor) }
            if errorDescriptor >= 0 { Darwin.close(errorDescriptor) }
            Darwin.close(masterDescriptor)
            throw SSHSessionError.pseudoTerminalUnavailable(
                message: String(cString: strerror(errno))
            )
        }

        master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
        standardInput = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
        standardOutput = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        standardError = FileHandle(fileDescriptor: errorDescriptor, closeOnDealloc: true)
        #else
        throw SSHSessionError.pseudoTerminalUnavailable(
            message: "Pseudo-terminals are unavailable on this platform."
        )
        #endif
    }

    func closeChildHandles() {
        try? standardInput.close()
        try? standardOutput.close()
        try? standardError.close()
    }

    func resize(columns: Int, rows: Int) throws {
        #if canImport(Darwin)
        var size = winsize(
            ws_row: UInt16(clamping: max(1, rows)),
            ws_col: UInt16(clamping: max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard Darwin.ioctl(master.fileDescriptor, TIOCSWINSZ, &size) == 0 else {
            throw SSHSessionError.pseudoTerminalUnavailable(
                message: String(cString: strerror(errno))
            )
        }
        #else
        throw SSHSessionError.pseudoTerminalUnavailable(
            message: "Pseudo-terminals are unavailable on this platform."
        )
        #endif
    }

    func close() {
        master.readabilityHandler = nil
        closeChildHandles()
        try? master.close()
    }
}
