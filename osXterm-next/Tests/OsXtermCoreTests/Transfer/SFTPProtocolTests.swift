import Foundation
import Testing
@testable import OsXtermCore

@Suite
struct SFTPProtocolTests {
    @Test
    func initializeRequestUsesExactVersionThreeFraming() throws {
        let packet = try SFTPCodec.encode(.initialize())

        #expect(packet == Data([0, 0, 0, 5, 1, 0, 0, 0, 3]))
        #expect(
            try SFTPCodec.decodePacket(packet)
                == SFTPFrame(type: .initialize, payload: Data([0, 0, 0, 3]))
        )
    }

    @Test
    func streamDecoderBuffersFragmentsAndReturnsCompleteFramesInOrder() throws {
        let first = try SFTPCodec.encode(
            SFTPFrame(type: .close, requestID: 4, payload: Data([0, 0, 0, 0]))
        )
        let second = try SFTPCodec.encode(
            SFTPFrame(type: .status, requestID: 4, payload: Data(repeating: 0, count: 12))
        )
        var decoder = SFTPStreamDecoder()

        #expect(try decoder.append(Data(first.prefix(3))).isEmpty)
        #expect(try decoder.append(Data(first.dropFirst(3))) == [
            SFTPFrame(type: .close, requestID: 4, payload: Data([0, 0, 0, 0]))
        ])
        #expect(try decoder.append(first + second) == [
            SFTPFrame(type: .close, requestID: 4, payload: Data([0, 0, 0, 0])),
            SFTPFrame(type: .status, requestID: 4, payload: Data(repeating: 0, count: 12))
        ])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func decodesDirectoryMetadataWithoutParsingLongnameText() throws {
        var payload = Data()
        appendUInt32(1, to: &payload)
        appendString("한글 file with spaces", to: &payload)
        appendString("server presentation text that is never parsed", to: &payload)
        appendUInt32(0x0000_0005, to: &payload)
        appendUInt64(42, to: &payload)
        appendUInt32(0o100640, to: &payload)
        let packet = try SFTPCodec.encode(
            SFTPFrame(type: .name, requestID: 71, payload: payload)
        )

        let response = try SFTPCodec.decodeResponse(try SFTPCodec.decodePacket(packet))
        #expect(response == .name(
            requestID: 71,
            entries: [
                SFTPNameEntry(
                    filename: "한글 file with spaces",
                    longname: "server presentation text that is never parsed",
                    attributes: SFTPFileAttributes(size: 42, permissions: 0o100640)
                )
            ]
        ))
    }

    @Test
    func rejectsTruncatedStringsAndExcessiveCollectionCounts() throws {
        var truncatedPayload = Data()
        appendUInt32(8, to: &truncatedPayload)
        truncatedPayload.append(Data("too".utf8))
        let truncated = try SFTPCodec.encode(
            SFTPFrame(type: .handle, requestID: 1, payload: truncatedPayload)
        )

        #expect(throws: SFTPProtocolError.invalidStringLength(8)) {
            _ = try SFTPCodec.decodeResponse(try SFTPCodec.decodePacket(truncated))
        }

        var oversizedPayload = Data()
        appendUInt32(SFTPCodec.defaultMaximumCollectionEntries + 1, to: &oversizedPayload)
        let oversized = try SFTPCodec.encode(
            SFTPFrame(type: .name, requestID: 2, payload: oversizedPayload)
        )
        #expect(throws: SFTPProtocolError.invalidCollectionCount(SFTPCodec.defaultMaximumCollectionEntries + 1)) {
            _ = try SFTPCodec.decodeResponse(try SFTPCodec.decodePacket(oversized))
        }
    }

    @Test
    func requestEncodingPreservesWhitespaceAndRejectsNULPaths() throws {
        let path = try SFTPRemotePath(rawValue: "/srv/한글 report\nwith spaces")
        let packet = try SFTPCodec.encode(
            .open(
                requestID: 9,
                path: path,
                flags: [.read],
                attributes: SFTPFileAttributes()
            )
        )
        let frame = try SFTPCodec.decodePacket(packet)
        #expect(frame.type == .open)
        #expect(frame.requestID == 9)
        #expect(frame.payload.contains(Data("한글 report\nwith spaces".utf8)))

        #expect(throws: SFTPProtocolError.invalidPath("Path cannot contain NUL")) {
            _ = try SFTPRemotePath(rawValue: "/srv/unsafe\0name")
        }
    }

    @Test
    func refusesPacketsAboveConfiguredLimit() throws {
        let packet = try SFTPCodec.encode(
            SFTPFrame(type: .data, requestID: 1, payload: Data(repeating: 0, count: 32))
        )
        var decoder = SFTPStreamDecoder(maximumPacketLength: 16)

        #expect(throws: SFTPProtocolError.packetTooLarge(actual: 37, maximum: 16)) {
            _ = try decoder.append(packet)
        }
    }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
}

private func appendString(_ value: String, to data: inout Data) {
    let encoded = Data(value.utf8)
    appendUInt32(UInt32(encoded.count), to: &data)
    data.append(encoded)
}
