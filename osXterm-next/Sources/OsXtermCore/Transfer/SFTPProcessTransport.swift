import Foundation

public enum SFTPProcessTransportError: Error, Equatable, Sendable, LocalizedError {
    case processAlreadyClosed
    case processExited(status: Int32, diagnostics: String)

    public var errorDescription: String? {
        switch self {
        case .processAlreadyClosed:
            return "The SFTP subsystem is already closed."
        case let .processExited(status, diagnostics):
            let message = OpenSSHOutputSanitizer.displayMessage(diagnostics)
            return message.isEmpty
                ? "The SFTP subsystem exited with status \(status)."
                : "The SFTP subsystem exited with status \(status): \(message)"
        }
    }
}

/// Concrete byte transport for `ssh -s sftp`. It keeps the generated OpenSSH
/// configuration alive for the full subsystem lifetime and never parses a
/// shell-oriented directory listing. The caller supplies a prepared route and
/// an environment that contains helper IPC coordinates only, never a secret.
public actor SFTPProcessTransport: SFTPByteTransport {
    private let preparedCommand: PreparedOpenSSHCommand
    private let process: Process
    private let standardInput: FileHandle
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private var incomingChunks: [Data] = []
    private var waitingReceivers: [CheckedContinuation<Data?, Error>] = []
    private var outputFinished = false
    private var outputFailure: SFTPProcessTransportError?
    private var standardErrorData = Data()
    private var isClosed = false
    private var terminationStatus: Int32?

    public init(
        preparedCommand: PreparedOpenSSHCommand,
        environment: [String: String],
        diagnosticsHandler: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard case .subsystem("sftp") = preparedCommand.invocation.purpose else {
            throw SFTPProcessTransportError.processAlreadyClosed
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process = Process()
        process.executableURL = preparedCommand.invocation.executableURL
        process.arguments = preparedCommand.invocation.arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        standardError = errorPipe.fileHandleForReading
        self.preparedCommand = preparedCommand

        standardOutput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { await self?.finishOutput() }
            } else {
                Task { await self?.receiveOutput(data) }
            }
        }
        standardError.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            diagnosticsHandler?(text)
            Task { await self?.appendStandardError(data) }
        }
        process.terminationHandler = { [weak self] task in
            Task { await self?.recordTermination(status: task.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            standardOutput.readabilityHandler = nil
            standardError.readabilityHandler = nil
            throw error
        }
    }

    deinit {
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    public func send(_ bytes: Data) async throws {
        guard !isClosed else { throw SFTPProcessTransportError.processAlreadyClosed }
        guard process.isRunning else {
            throw SFTPProcessTransportError.processExited(
                status: terminationStatus ?? process.terminationStatus,
                diagnostics: String(decoding: standardErrorData, as: UTF8.self)
            )
        }
        try standardInput.write(contentsOf: bytes)
    }

    public func receive() async throws -> Data? {
        guard !isClosed else { return nil }
        if !incomingChunks.isEmpty {
            return incomingChunks.removeFirst()
        }
        if let outputFailure {
            throw outputFailure
        }
        if outputFinished {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            waitingReceivers.append(continuation)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
        try? standardInput.close()
        if process.isRunning {
            process.terminate()
        }
        finishOutput()
        preparedCommand.configuration.cleanup()
    }

    public func diagnosticText() -> String {
        String(decoding: standardErrorData, as: UTF8.self)
    }

    private func appendStandardError(_ data: Data) {
        let maximum = 64 * 1024
        if standardErrorData.count + data.count > maximum {
            let retained = max(0, maximum - data.count)
            standardErrorData = Data(standardErrorData.suffix(retained))
        }
        standardErrorData.append(data)
    }

    private func recordTermination(status: Int32) {
        terminationStatus = status
        if status != 0, !isClosed {
            let diagnostics = String(decoding: standardErrorData, as: UTF8.self)
            finishOutput(SFTPProcessTransportError.processExited(
                status: status,
                diagnostics: diagnostics
            ))
        }
    }

    private func receiveOutput(_ data: Data) {
        guard !outputFinished else { return }
        if waitingReceivers.isEmpty {
            incomingChunks.append(data)
        } else {
            waitingReceivers.removeFirst().resume(returning: data)
        }
    }

    private func finishOutput(_ failure: SFTPProcessTransportError? = nil) {
        guard !outputFinished else { return }
        outputFinished = true
        outputFailure = failure
        let receivers = waitingReceivers
        waitingReceivers.removeAll()
        for receiver in receivers {
            if let failure {
                receiver.resume(throwing: failure)
            } else {
                receiver.resume(returning: nil)
            }
        }
    }
}
