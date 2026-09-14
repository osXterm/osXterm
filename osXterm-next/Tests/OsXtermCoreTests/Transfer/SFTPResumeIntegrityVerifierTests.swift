import Foundation
import Testing
@testable import OsXtermCore

@Suite
struct SFTPResumeIntegrityVerifierTests {
    @Test
    func resumesOnlyWhenTheStructuredRemotePrefixMatchesTheLocalFile() async throws {
        let localData = Data("prefix-data".utf8)
        let localURL = try temporaryFile(containing: localData)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        let (client, transport) = try scriptedClient(remoteData: localData)
        _ = try await client.initialize()
        let verifier = SFTPResumeIntegrityVerifier(client: client)

        #expect(try await verifier.localAndRemotePrefixMatch(
            localURL: localURL,
            remotePath: SFTPRemotePath(rawValue: "/srv/resume target"),
            byteCount: Int64(localData.count)
        ))

        let frames = try await transport.sentFrames()
        #expect(frames.map(\.type) == [.initialize, .open, .read, .close])
    }

    @Test
    func rejectsAChangedRemotePrefixBeforeAppendMode() async throws {
        let localData = Data("prefix-data".utf8)
        let localURL = try temporaryFile(containing: localData)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        let (client, _) = try scriptedClient(remoteData: Data("prefix-DATA".utf8))
        _ = try await client.initialize()
        let verifier = SFTPResumeIntegrityVerifier(client: client)

        #expect(try await verifier.localAndRemotePrefixMatch(
            localURL: localURL,
            remotePath: SFTPRemotePath(rawValue: "/srv/resume target"),
            byteCount: Int64(localData.count)
        ) == false)
    }

    private func temporaryFile(containing data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osxterm-resume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("resume source.bin")
        try data.write(to: file)
        return file
    }

    private func scriptedClient(remoteData: Data) throws -> (SFTPClient, ResumeVerifierTransport) {
        let transport = ResumeVerifierTransport(incoming: try [
            response(type: .version, payload: uint32Data(3)),
            response(type: .handle, requestID: 1, payload: stringData("resume-handle")),
            response(type: .data, requestID: 2, payload: dataPayload(remoteData)),
            response(type: .status, requestID: 3, payload: statusPayload(code: 0, message: "OK"))
        ])
        return (SFTPClient(transport: transport), transport)
    }
}

private actor ResumeVerifierTransport: SFTPByteTransport {
    private var incoming: [Data]
    private var sent: [Data] = []

    init(incoming: [Data]) {
        self.incoming = incoming
    }

    func send(_ bytes: Data) async throws {
        sent.append(bytes)
    }

    func receive() async throws -> Data? {
        guard !incoming.isEmpty else { return nil }
        return incoming.removeFirst()
    }

    func close() async {}

    func sentFrames() throws -> [SFTPFrame] {
        try sent.map { try SFTPCodec.decodePacket($0) }
    }
}

private func response(type: SFTPMessageType, requestID: UInt32? = nil, payload: Data) throws -> Data {
    try SFTPCodec.encode(SFTPFrame(type: type, requestID: requestID, payload: payload))
}

private func uint32Data(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ])
}

private func stringData(_ value: String) -> Data {
    dataPayload(Data(value.utf8))
}

private func dataPayload(_ value: Data) -> Data {
    uint32Data(UInt32(value.count)) + value
}

private func statusPayload(code: UInt32, message: String) -> Data {
    uint32Data(code) + stringData(message) + stringData("")
}
