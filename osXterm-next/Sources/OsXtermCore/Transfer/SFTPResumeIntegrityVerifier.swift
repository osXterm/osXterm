import CryptoKit
import Foundation

/// Verifies the bytes already present at an SFTP destination before a retry
/// appends to it. The verifier runs on its own actor so local file reads do
/// not execute on the caller's UI actor.
public actor SFTPResumeIntegrityVerifier {
    private let client: SFTPClient
    private let chunkSize = 64 * 1024

    public init(client: SFTPClient) {
        self.client = client
    }

    /// Returns false when either side is shorter than the intended prefix or
    /// when the SHA-256 digests differ. I/O and protocol failures still throw
    /// so callers can distinguish a retry safety decision from a failed link.
    public func localAndRemotePrefixMatch(
        localURL: URL,
        remotePath: SFTPRemotePath,
        byteCount: Int64
    ) async throws -> Bool {
        guard byteCount > 0,
              let localDigest = try localPrefixSHA256(at: localURL, byteCount: byteCount),
              let remoteDigest = try await remotePrefixSHA256(
                  at: remotePath,
                  byteCount: byteCount
              )
        else {
            return false
        }
        return localDigest == remoteDigest
    }

    private func localPrefixSHA256(at url: URL, byteCount: Int64) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var remaining = byteCount
        var hasher = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let maximumChunkSize = Int(min(remaining, Int64(chunkSize)))
            let chunk = try handle.read(upToCount: maximumChunkSize) ?? Data()
            guard !chunk.isEmpty else { return nil }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return Data(hasher.finalize())
    }

    private func remotePrefixSHA256(
        at path: SFTPRemotePath,
        byteCount: Int64
    ) async throws -> Data? {
        let handle = try await client.open(path: path, flags: [.read])
        do {
            var remaining = byteCount
            var offset: UInt64 = 0
            var hasher = SHA256()
            while remaining > 0 {
                try Task.checkCancellation()
                let maximumChunkSize = UInt32(min(remaining, Int64(chunkSize)))
                guard let chunk = try await client.read(
                    from: handle,
                    offset: offset,
                    length: maximumChunkSize
                ), !chunk.isEmpty else {
                    try await client.close(handle)
                    return nil
                }
                hasher.update(data: chunk)
                remaining -= Int64(chunk.count)
                offset += UInt64(chunk.count)
            }
            try await client.close(handle)
            return Data(hasher.finalize())
        } catch {
            try? await client.close(handle)
            throw error
        }
    }
}
