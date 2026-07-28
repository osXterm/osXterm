import Foundation

/// Runs one SFTP operation on a detached task so a caller's actor, including
/// the terminal UI actor, is never held by process setup or file transfer I/O.
public enum SFTPExecutor {
    public static func run<T: Sendable>(
        client: SFTPClient,
        operation: @escaping @Sendable (SFTPClient) async throws -> T
    ) async throws -> T {
        let work = Task.detached(priority: .userInitiated) {
            try await operation(client)
        }

        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
