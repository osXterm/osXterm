import Foundation

public protocol SFTPProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        environment: [String: String]
    ) async throws -> SFTPProcessResult
}

public struct SystemSFTPProcessRunner: SFTPProcessRunning {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        environment: [String: String]
    ) async throws -> SFTPProcessResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osxterm-sftp-\(UUID().uuidString)", isDirectory: true)
        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ), FileManager.default.createFile(
                atPath: errorURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw SFTPError.processLaunchFailed("Could not create output capture files")
            }
        } catch let error as SFTPError {
            throw error
        } catch {
            throw SFTPError.processLaunchFailed(error.localizedDescription)
        }

        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let standardOutputHandle: FileHandle
        let standardErrorHandle: FileHandle
        do {
            standardOutputHandle = try FileHandle(forWritingTo: outputURL)
            standardErrorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            throw SFTPError.processLaunchFailed(error.localizedDescription)
        }

        let inputPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle

        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, suppliedValue in suppliedValue }
            )
        }

        let cancellationState = SFTPProcessCancellationState(process: process)
        let continuationGate = SFTPContinuationGate()

        let terminationStatus = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { completedProcess in
                    if continuationGate.claim() {
                        continuation.resume(returning: completedProcess.terminationStatus)
                    }
                }

                do {
                    try process.run()
                    cancellationState.processDidLaunch()
                    try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                    try inputPipe.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    try? inputPipe.fileHandleForWriting.close()
                    if continuationGate.claim() {
                        continuation.resume(
                            throwing: SFTPError.processLaunchFailed(error.localizedDescription)
                        )
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }

        try? standardOutputHandle.close()
        try? standardErrorHandle.close()

        if Task.isCancelled {
            throw CancellationError()
        }

        do {
            return SFTPProcessResult(
                terminationStatus: terminationStatus,
                standardOutput: try Data(contentsOf: outputURL),
                standardError: try Data(contentsOf: errorURL)
            )
        } catch {
            throw SFTPError.processLaunchFailed(error.localizedDescription)
        }
    }
}

private final class SFTPContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasBeenClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !hasBeenClaimed else {
            return false
        }
        hasBeenClaimed = true
        return true
    }
}

private final class SFTPProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var didLaunch = false
    private var cancellationRequested = false

    init(process: Process) {
        self.process = process
    }

    func processDidLaunch() {
        lock.lock()
        didLaunch = true
        let shouldTerminate = cancellationRequested
        lock.unlock()

        if shouldTerminate {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let shouldTerminate = didLaunch
        lock.unlock()

        if shouldTerminate {
            process.terminate()
        }
    }
}
