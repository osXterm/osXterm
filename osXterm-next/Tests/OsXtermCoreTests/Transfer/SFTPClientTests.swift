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

    @Test(arguments: ["../outside", "/absolute", "nested/file", "", "bad\0name"])
    func rejectsNamesThatCouldEscapeTheDownloadDirectory(_ name: String) async throws {
        let transport = ScriptedSFTPTransport(incoming: try [
            packet(type: .version, payload: uint32Data(3)),
            packet(type: .handle, requestID: 1, payload: stringData("directory-handle")),
            packet(type: .name, requestID: 2, payload: namePayload(filename: name, longname: "ignored", size: 0)),
            packet(type: .status, requestID: 3, payload: statusPayload(code: 0, message: "OK"))
        ])
        let client = SFTPClient(transport: transport)
        _ = try await client.initialize()
        await #expect(throws: SFTPClientError.unsafeDirectoryEntry(name)) {
            _ = try await client.listDirectory(SFTPRemotePath(rawValue: "/srv"))
        }
        #expect(try await transport.sentFrames().map(\.type) == [.initialize, .openDirectory, .readDirectory, .close])
    }

    @Test
    func rejectsDuplicateNamesAcrossDirectoryPages() async throws {
        let transport = ScriptedSFTPTransport(incoming: try [
            packet(type: .version, payload: uint32Data(3)),
            packet(type: .handle, requestID: 1, payload: stringData("directory-handle")),
            packet(type: .name, requestID: 2, payload: namePayload(filename: "duplicate", longname: "ignored", size: 0)),
            packet(type: .name, requestID: 3, payload: namePayload(filename: "duplicate", longname: "different attributes", size: 4096)),
            packet(type: .status, requestID: 4, payload: statusPayload(code: 0, message: "OK"))
        ])
        let client = SFTPClient(transport: transport)
        _ = try await client.initialize()
        await #expect(throws: SFTPClientError.duplicateDirectoryEntry("duplicate")) {
            _ = try await client.listDirectory(SFTPRemotePath(rawValue: "/srv"))
        }
        #expect(try await transport.sentFrames().last?.type == .close)
    }

    @Test
    func concurrentTransfersKeepRequestResponseExchangesSerialized() async throws {
        let transport = ConcurrentSFTPTransport()
        let client = SFTPClient(transport: transport)
        _ = try await client.initialize()
        let sizes = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for index in 1 ... 12 {
                group.addTask {
                    let attributes = try await client.attributes(of: SFTPRemotePath(rawValue: "/file-\(index)"))
                    #expect(attributes.size == UInt64(index))
                    return attributes.size ?? 0
                }
            }
            var results: [UInt64] = []
            for try await size in group { results.append(size) }
            return results.sorted()
        }
        #expect(sizes == Array(1 ... 12).map(UInt64.init))
        #expect(await transport.maximumOutstandingRequests == 1)
    }
}

private actor ConcurrentSFTPTransport: SFTPByteTransport {
    private var incoming: [Data] = []
    private var outstandingRequests = 0
    private(set) var maximumOutstandingRequests = 0

    func send(_ bytes: Data) throws {
        let frame = try SFTPCodec.decodePacket(bytes)
        if frame.type == .initialize {
            incoming.append(try packet(type: .version, payload: uint32Data(3)))
        } else {
            let path = String(decoding: frame.payload.dropFirst(4), as: UTF8.self)
            let value = UInt64(path.split(separator: "-").last ?? "0") ?? 0
            let size = withUnsafeBytes(of: value.bigEndian) { Data($0) }
            incoming.append(try packet(type: .attributes, requestID: frame.requestID, payload: uint32Data(1) + size))
        }
        outstandingRequests += 1
        maximumOutstandingRequests = max(maximumOutstandingRequests, outstandingRequests)
    }

    func receive() async throws -> Data? {
        // Give other client calls time to enter while this receive suspends.
        try await Task.sleep(for: .milliseconds(2))
        guard !incoming.isEmpty else { return nil }
        outstandingRequests -= 1
        return incoming.removeFirst()
    }

    func close() async {}
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
