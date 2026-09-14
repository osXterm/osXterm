import Foundation
import Testing
@testable import OsXtermCore

@Suite
struct SFTPClientTests {
    @Test
    func listsDirectoryThroughStructuredSubsystemPackets() async throws {
        let transport = ScriptedSFTPTransport(incoming: try [
            packet(type: .version, payload: uint32Data(3)),
            packet(type: .handle, requestID: 1, payload: stringData("directory-handle")),
            packet(type: .name, requestID: 2, payload: namePayload(
                filename: "한글 file with spaces",
                longname: "untrusted display text",
                size: 12
            )),
            packet(type: .status, requestID: 3, payload: statusPayload(code: 1, message: "EOF")),
            packet(type: .status, requestID: 4, payload: statusPayload(code: 0, message: "OK"))
        ])
        let client = SFTPClient(transport: transport)

        #expect(try await client.initialize().version == 3)
        let entries = try await client.listDirectory(SFTPRemotePath(rawValue: "/srv"))

        #expect(entries.map(\.filename) == ["한글 file with spaces"])
        #expect(entries.first?.attributes.size == 12)
        let sent = try await transport.sentFrames()
        #expect(sent.map(\.type) == [
            .initialize,
            .openDirectory,
            .readDirectory,
            .readDirectory,
            .close
        ])
    }

    @Test
    func refusesOperationsUntilTheServerVersionHandshakeCompletes() async throws {
        let client = SFTPClient(transport: ScriptedSFTPTransport(incoming: []))

        await #expect(throws: SFTPClientError.handshakeRequired) {
            _ = try await client.open(
                path: SFTPRemotePath(rawValue: "/srv/file"),
                flags: [.read]
            )
        }
    }
}

private actor ScriptedSFTPTransport: SFTPByteTransport {
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

private func packet(type: SFTPMessageType, requestID: UInt32? = nil, payload: Data) throws -> Data {
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
    let data = Data(value.utf8)
    return uint32Data(UInt32(data.count)) + data
}

private func namePayload(filename: String, longname: String, size: UInt64) -> Data {
    uint32Data(1)
        + stringData(filename)
        + stringData(longname)
        + uint32Data(1)
        + Data([
            UInt8((size >> 56) & 0xFF),
            UInt8((size >> 48) & 0xFF),
            UInt8((size >> 40) & 0xFF),
            UInt8((size >> 32) & 0xFF),
            UInt8((size >> 24) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF)
        ])
}

private func statusPayload(code: UInt32, message: String) -> Data {
    uint32Data(code) + stringData(message) + stringData("")
}
