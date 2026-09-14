import Foundation

/// SFTP protocol version used by osXterm. The implementation deliberately
/// speaks the binary v3 protocol instead of parsing `sftp` command output.
public enum SFTPProtocolVersion {
    public static let v3: UInt32 = 3
}

public enum SFTPMessageType: UInt8, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case openDirectory = 11
    case readDirectory = 12
    case remove = 13
    case makeDirectory = 14
    case removeDirectory = 15
    case realPath = 16
    case stat = 17
    case rename = 18
    case readLink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extended = 200
    case extendedReply = 201

    fileprivate var carriesRequestID: Bool {
        self != .initialize && self != .version
    }
}

public enum SFTPProtocolError: Error, Equatable, Sendable {
    case packetTooLarge(actual: Int, maximum: Int)
    case malformedPacketLength(expected: Int, actual: Int)
    case truncatedPacket
    case invalidMessageType(UInt8)
    case missingRequestID(SFTPMessageType)
    case unexpectedRequestID(SFTPMessageType)
    case invalidUTF8
    case invalidStringLength(UInt32)
    case invalidCollectionCount(UInt32)
    case invalidAttributeFlags(UInt32)
    case invalidVersion(UInt32)
    case invalidPath(String)
    case invalidRequest(String)
    case trailingPayload(Int)
}

extension SFTPProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .packetTooLarge(actual, maximum):
            "SFTP packet size \(actual) exceeds the \(maximum) byte limit."
        case let .malformedPacketLength(expected, actual):
            "SFTP packet length is \(actual), expected \(expected)."
        case .truncatedPacket:
            "SFTP packet ended before all fields were received."
        case let .invalidMessageType(value):
            "SFTP packet has unknown message type \(value)."
        case let .missingRequestID(type):
            "SFTP \(type) packet requires a request identifier."
        case let .unexpectedRequestID(type):
            "SFTP \(type) packet cannot have a request identifier."
        case .invalidUTF8:
            "SFTP packet contains a string that is not UTF-8."
        case let .invalidStringLength(length):
            "SFTP packet declares an invalid string length \(length)."
        case let .invalidCollectionCount(count):
            "SFTP packet declares an unsafe collection count \(count)."
        case let .invalidAttributeFlags(flags):
            "SFTP packet has unsupported attribute flags \(flags)."
        case let .invalidVersion(version):
            "SFTP server selected unsupported version \(version)."
        case let .invalidPath(path):
            "SFTP path is invalid: \(path)"
        case let .invalidRequest(message):
            "SFTP request is invalid: \(message)"
        case let .trailingPayload(count):
            "SFTP packet has \(count) unexpected trailing bytes."
        }
    }
}

/// A length-delimited SFTP packet with its protocol framing removed.
public struct SFTPFrame: Equatable, Sendable {
    public let type: SFTPMessageType
    public let requestID: UInt32?
    public let payload: Data

    public init(type: SFTPMessageType, requestID: UInt32? = nil, payload: Data = Data()) {
        self.type = type
        self.requestID = requestID
        self.payload = payload
    }
}

public struct SFTPStreamDecoder: Sendable {
    public let maximumPacketLength: Int
    private var buffer: Data

    public init(maximumPacketLength: Int = SFTPCodec.defaultMaximumPacketLength) {
        self.maximumPacketLength = maximumPacketLength
        buffer = Data()
    }

    /// Adds bytes from the subsystem stream and returns every complete packet.
    /// Incomplete trailing bytes remain buffered for the next read.
    public mutating func append(_ bytes: Data) throws -> [SFTPFrame] {
        guard maximumPacketLength >= 5 else {
            throw SFTPProtocolError.invalidRequest("Maximum packet length must include type and id")
        }

        buffer.append(bytes)
        var frames: [SFTPFrame] = []

        while buffer.count >= MemoryLayout<UInt32>.size {
            let declaredLength = try SFTPCodec.lengthPrefix(in: buffer)
            let packetLength = Int(declaredLength)
            guard packetLength <= maximumPacketLength else {
                throw SFTPProtocolError.packetTooLarge(
                    actual: packetLength,
                    maximum: maximumPacketLength
                )
            }

            let totalLength = packetLength + MemoryLayout<UInt32>.size
            guard buffer.count >= totalLength else {
                break
            }

            let packet = Data(buffer.prefix(totalLength))
            buffer.removeFirst(totalLength)
            frames.append(try SFTPCodec.decodePacket(packet, maximumPacketLength: maximumPacketLength))
        }

        return frames
    }

    public var bufferedByteCount: Int { buffer.count }
}

public enum SFTPCodec {
    public static let defaultMaximumPacketLength = 16 * 1024 * 1024
    public static let defaultMaximumCollectionEntries: UInt32 = 100_000

    public static func encode(
        _ frame: SFTPFrame,
        maximumPacketLength: Int = defaultMaximumPacketLength
    ) throws -> Data {
        guard maximumPacketLength >= 5 else {
            throw SFTPProtocolError.invalidRequest("Maximum packet length must include type and id")
        }

        if frame.type.carriesRequestID {
            guard frame.requestID != nil else {
                throw SFTPProtocolError.missingRequestID(frame.type)
            }
        } else if frame.requestID != nil {
            throw SFTPProtocolError.unexpectedRequestID(frame.type)
        }

        var body = SFTPBinaryEncoder()
        body.append(frame.type.rawValue)
        if let requestID = frame.requestID {
            body.append(requestID)
        }
        body.append(frame.payload)

        guard body.data.count <= maximumPacketLength else {
            throw SFTPProtocolError.packetTooLarge(
                actual: body.data.count,
                maximum: maximumPacketLength
            )
        }

        var packet = SFTPBinaryEncoder()
        guard let frameLength = UInt32(exactly: body.data.count) else {
            throw SFTPProtocolError.packetTooLarge(
                actual: body.data.count,
                maximum: Int(UInt32.max)
            )
        }
        packet.append(frameLength)
        packet.append(body.data)
        return packet.data
    }

    public static func decodePacket(
        _ packet: Data,
        maximumPacketLength: Int = defaultMaximumPacketLength
    ) throws -> SFTPFrame {
        guard packet.count >= 5 else {
            throw SFTPProtocolError.truncatedPacket
        }

        let declaredLength = try lengthPrefix(in: packet)
        let expectedLength = Int(declaredLength) + MemoryLayout<UInt32>.size
        guard Int(declaredLength) <= maximumPacketLength else {
            throw SFTPProtocolError.packetTooLarge(
                actual: Int(declaredLength),
                maximum: maximumPacketLength
            )
        }
        guard packet.count == expectedLength else {
            throw SFTPProtocolError.malformedPacketLength(
                expected: expectedLength,
                actual: packet.count
            )
        }

        var decoder = SFTPBinaryDecoder(data: Data(packet.dropFirst(4)))
        let rawType = try decoder.readByte()
        guard let type = SFTPMessageType(rawValue: rawType) else {
            throw SFTPProtocolError.invalidMessageType(rawType)
        }
        let requestID = type.carriesRequestID ? try decoder.readUInt32() : nil
        return SFTPFrame(type: type, requestID: requestID, payload: try decoder.readRemaining())
    }

    public static func encode(_ request: SFTPRequest) throws -> Data {
        try encode(request.frame)
    }

    public static func decodeResponse(_ frame: SFTPFrame) throws -> SFTPResponse {
        var decoder = SFTPBinaryDecoder(data: frame.payload)

        switch frame.type {
        case .version:
            let version = try decoder.readUInt32()
            guard version == SFTPProtocolVersion.v3 else {
                throw SFTPProtocolError.invalidVersion(version)
            }
            var extensions: [String: String] = [:]
            while !decoder.isAtEnd {
                let name = try decoder.readString()
                let value = try decoder.readString()
                extensions[name] = value
            }
            return .version(version: version, extensions: extensions)

        case .status:
            let requestID = try requiredRequestID(from: frame)
            let code = try decoder.readUInt32()
            let message = try decoder.readString()
            let languageTag = try decoder.readString()
            try decoder.requireAtEnd()
            return .status(
                requestID: requestID,
                status: SFTPStatus(code: code),
                message: message,
                languageTag: languageTag
            )

        case .handle:
            let requestID = try requiredRequestID(from: frame)
            let handle = try decoder.readData()
            try decoder.requireAtEnd()
            return .handle(requestID: requestID, handle: handle)

        case .data:
            let requestID = try requiredRequestID(from: frame)
            let data = try decoder.readData()
            try decoder.requireAtEnd()
            return .data(requestID: requestID, data: data)

        case .name:
            let requestID = try requiredRequestID(from: frame)
            let count = try decoder.readUInt32()
            guard count <= defaultMaximumCollectionEntries else {
                throw SFTPProtocolError.invalidCollectionCount(count)
            }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                entries.append(
                    SFTPNameEntry(
                        filename: try decoder.readString(),
                        longname: try decoder.readString(),
                        attributes: try SFTPFileAttributes(decoding: &decoder)
                    )
                )
            }
            try decoder.requireAtEnd()
            return .name(requestID: requestID, entries: entries)

        case .attributes:
            let requestID = try requiredRequestID(from: frame)
            let attributes = try SFTPFileAttributes(decoding: &decoder)
            try decoder.requireAtEnd()
            return .attributes(requestID: requestID, attributes: attributes)

        case .extendedReply:
            let requestID = try requiredRequestID(from: frame)
            return .extendedReply(requestID: requestID, payload: try decoder.readRemaining())

        default:
            throw SFTPProtocolError.invalidRequest("Packet type \(frame.type) is not an SFTP response")
        }
    }

    fileprivate static func lengthPrefix(in packet: Data) throws -> UInt32 {
        guard packet.count >= 4 else {
            throw SFTPProtocolError.truncatedPacket
        }
        var decoder = SFTPBinaryDecoder(data: Data(packet.prefix(4)))
        return try decoder.readUInt32()
    }

    private static func requiredRequestID(from frame: SFTPFrame) throws -> UInt32 {
        guard let requestID = frame.requestID else {
            throw SFTPProtocolError.missingRequestID(frame.type)
        }
        return requestID
    }
}

public struct SFTPStatus: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(code: UInt32) {
        rawValue = code
    }

    public static let ok = SFTPStatus(rawValue: 0)
    public static let endOfFile = SFTPStatus(rawValue: 1)
    public static let noSuchFile = SFTPStatus(rawValue: 2)
    public static let permissionDenied = SFTPStatus(rawValue: 3)
    public static let failure = SFTPStatus(rawValue: 4)
    public static let badMessage = SFTPStatus(rawValue: 5)
    public static let noConnection = SFTPStatus(rawValue: 6)
    public static let connectionLost = SFTPStatus(rawValue: 7)
    public static let operationUnsupported = SFTPStatus(rawValue: 8)
}

public struct SFTPFileAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var owner: UInt32?
    public var group: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?
    public var extended: [SFTPExtendedAttribute]

    public init(
        size: UInt64? = nil,
        owner: UInt32? = nil,
        group: UInt32? = nil,
        permissions: UInt32? = nil,
        accessTime: UInt32? = nil,
        modificationTime: UInt32? = nil,
        extended: [SFTPExtendedAttribute] = []
    ) {
        self.size = size
        self.owner = owner
        self.group = group
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
        self.extended = extended
    }

    fileprivate init(decoding decoder: inout SFTPBinaryDecoder) throws {
        let flags = try decoder.readUInt32()
        let recognizedFlags: UInt32 = 0x8000_000F
        guard flags & ~recognizedFlags == 0 else {
            throw SFTPProtocolError.invalidAttributeFlags(flags)
        }

        size = flags & 0x0000_0001 != 0 ? try decoder.readUInt64() : nil
        if flags & 0x0000_0002 != 0 {
            owner = try decoder.readUInt32()
            group = try decoder.readUInt32()
        } else {
            owner = nil
            group = nil
        }
        permissions = flags & 0x0000_0004 != 0 ? try decoder.readUInt32() : nil
        if flags & 0x0000_0008 != 0 {
            accessTime = try decoder.readUInt32()
            modificationTime = try decoder.readUInt32()
        } else {
            accessTime = nil
            modificationTime = nil
        }

        if flags & 0x8000_0000 != 0 {
            let count = try decoder.readUInt32()
            guard count <= SFTPCodec.defaultMaximumCollectionEntries else {
                throw SFTPProtocolError.invalidCollectionCount(count)
            }
            var attributes: [SFTPExtendedAttribute] = []
            attributes.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                attributes.append(
                    SFTPExtendedAttribute(
                        type: try decoder.readString(),
                        data: try decoder.readString()
                    )
                )
            }
            extended = attributes
        } else {
            extended = []
        }
    }

    fileprivate func encode(to encoder: inout SFTPBinaryEncoder) throws {
        guard (owner == nil) == (group == nil) else {
            throw SFTPProtocolError.invalidRequest("Owner and group must be supplied together")
        }
        guard (accessTime == nil) == (modificationTime == nil) else {
            throw SFTPProtocolError.invalidRequest("Access and modification times must be supplied together")
        }

        var flags: UInt32 = 0
        if size != nil { flags |= 0x0000_0001 }
        if owner != nil { flags |= 0x0000_0002 }
        if permissions != nil { flags |= 0x0000_0004 }
        if accessTime != nil { flags |= 0x0000_0008 }
        if !extended.isEmpty { flags |= 0x8000_0000 }
        encoder.append(flags)

        if let size { encoder.append(size) }
        if let owner, let group {
            encoder.append(owner)
            encoder.append(group)
        }
        if let permissions { encoder.append(permissions) }
        if let accessTime, let modificationTime {
            encoder.append(accessTime)
            encoder.append(modificationTime)
        }
        if !extended.isEmpty {
            guard let count = UInt32(exactly: extended.count) else {
                throw SFTPProtocolError.invalidRequest("Too many extended attributes")
            }
            encoder.append(count)
            for attribute in extended {
                try encoder.append(string: attribute.type)
                try encoder.append(string: attribute.data)
            }
        }
    }
}

public struct SFTPExtendedAttribute: Equatable, Sendable {
    public let type: String
    public let data: String

    public init(type: String, data: String) {
        self.type = type
        self.data = data
    }
}

public struct SFTPNameEntry: Equatable, Sendable {
    public let filename: String
    /// Server-provided presentation text retained for display only. It is not
    /// parsed for metadata; attributes remain the source of truth.
    public let longname: String
    public let attributes: SFTPFileAttributes

    public init(filename: String, longname: String, attributes: SFTPFileAttributes) {
        self.filename = filename
        self.longname = longname
        self.attributes = attributes
    }
}

public struct SFTPRemotePath: Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw SFTPProtocolError.invalidPath("Path cannot be empty")
        }
        guard !rawValue.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SFTPProtocolError.invalidPath("Path cannot contain NUL")
        }
        self.rawValue = rawValue
    }
}

public struct SFTPOpenFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    public static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    public static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    public static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    public static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x0000_0020)
}

public enum SFTPRequest: Equatable, Sendable {
    case initialize(version: UInt32 = SFTPProtocolVersion.v3)
    case open(requestID: UInt32, path: SFTPRemotePath, flags: SFTPOpenFlags, attributes: SFTPFileAttributes)
    case close(requestID: UInt32, handle: Data)
    case read(requestID: UInt32, handle: Data, offset: UInt64, length: UInt32)
    case write(requestID: UInt32, handle: Data, offset: UInt64, data: Data)
    case setstat(requestID: UInt32, path: SFTPRemotePath, attributes: SFTPFileAttributes)
    case openDirectory(requestID: UInt32, path: SFTPRemotePath)
    case readDirectory(requestID: UInt32, handle: Data)
    case remove(requestID: UInt32, path: SFTPRemotePath)
    case makeDirectory(requestID: UInt32, path: SFTPRemotePath, attributes: SFTPFileAttributes)
    case removeDirectory(requestID: UInt32, path: SFTPRemotePath)
    case realPath(requestID: UInt32, path: SFTPRemotePath)
    case stat(requestID: UInt32, path: SFTPRemotePath)
    case lstat(requestID: UInt32, path: SFTPRemotePath)
    case rename(requestID: UInt32, from: SFTPRemotePath, to: SFTPRemotePath)
    case readLink(requestID: UInt32, path: SFTPRemotePath)
    case symlink(requestID: UInt32, linkPath: SFTPRemotePath, targetPath: SFTPRemotePath)

    public var frame: SFTPFrame {
        get throws {
            var payload = SFTPBinaryEncoder()

            switch self {
            case let .initialize(version):
                payload.append(version)
                return SFTPFrame(type: .initialize, payload: payload.data)

            case let .open(requestID, path, flags, attributes):
                try payload.append(string: path.rawValue)
                payload.append(flags.rawValue)
                try attributes.encode(to: &payload)
                return SFTPFrame(type: .open, requestID: requestID, payload: payload.data)

            case let .close(requestID, handle):
                try payload.append(data: handle)
                return SFTPFrame(type: .close, requestID: requestID, payload: payload.data)

            case let .read(requestID, handle, offset, length):
                try payload.append(data: handle)
                payload.append(offset)
                payload.append(length)
                return SFTPFrame(type: .read, requestID: requestID, payload: payload.data)

            case let .write(requestID, handle, offset, data):
                try payload.append(data: handle)
                payload.append(offset)
                try payload.append(data: data)
                return SFTPFrame(type: .write, requestID: requestID, payload: payload.data)

            case let .setstat(requestID, path, attributes):
                try payload.append(string: path.rawValue)
                try attributes.encode(to: &payload)
                return SFTPFrame(type: .setstat, requestID: requestID, payload: payload.data)

            case let .openDirectory(requestID, path):
                try payload.append(string: path.rawValue)
                return SFTPFrame(type: .openDirectory, requestID: requestID, payload: payload.data)

            case let .readDirectory(requestID, handle):
                try payload.append(data: handle)
                return SFTPFrame(type: .readDirectory, requestID: requestID, payload: payload.data)

            case let .remove(requestID, path):
                try payload.append(string: path.rawValue)
                return SFTPFrame(type: .remove, requestID: requestID, payload: payload.data)

            case let .makeDirectory(requestID, path, attributes):
                try payload.append(string: path.rawValue)
                try attributes.encode(to: &payload)
                return SFTPFrame(type: .makeDirectory, requestID: requestID, payload: payload.data)

            case let .removeDirectory(requestID, path):
                try payload.append(string: path.rawValue)
                return SFTPFrame(type: .removeDirectory, requestID: requestID, payload: payload.data)

            case let .realPath(requestID, path):
                try payload.append(string: path.rawValue)
                return SFTPFrame(type: .realPath, requestID: requestID, payload: payload.data)

            case let .stat(requestID, path):
                try payload.append(string: path.rawValue)
                return SFTPFrame(type: .stat, requestID: requestID, payload: payload.data)

            case let .lstat(requestID, path):
                try payload.append(string: path.rawValue)
                return SFTPFrame(type: .lstat, requestID: requestID, payload: payload.data)

            case let .rename(requestID, from, to):
                try payload.append(string: from.rawValue)
                try payload.append(string: to.rawValue)
                return SFTPFrame(type: .rename, requestID: requestID, payload: payload.data)

            case let .readLink(requestID, path):
                try payload.append(string: path.rawValue)
                return SFTPFrame(type: .readLink, requestID: requestID, payload: payload.data)

            case let .symlink(requestID, linkPath, targetPath):
                try payload.append(string: targetPath.rawValue)
                try payload.append(string: linkPath.rawValue)
                return SFTPFrame(type: .symlink, requestID: requestID, payload: payload.data)
            }
        }
    }
}

public enum SFTPResponse: Equatable, Sendable {
    case version(version: UInt32, extensions: [String: String])
    case status(requestID: UInt32, status: SFTPStatus, message: String, languageTag: String)
    case handle(requestID: UInt32, handle: Data)
    case data(requestID: UInt32, data: Data)
    case name(requestID: UInt32, entries: [SFTPNameEntry])
    case attributes(requestID: UInt32, attributes: SFTPFileAttributes)
    case extendedReply(requestID: UInt32, payload: Data)
}

private struct SFTPBinaryEncoder {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func append(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func append(_ value: Data) {
        data.append(value)
    }

    mutating func append(data value: Data) throws {
        guard let length = UInt32(exactly: value.count) else {
            throw SFTPProtocolError.invalidStringLength(UInt32.max)
        }
        append(length)
        append(value)
    }

    mutating func append(string value: String) throws {
        try append(data: Data(value.utf8))
    }
}

private struct SFTPBinaryDecoder {
    private let data: Data
    private var index: Int = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { index == data.count }

    mutating func readByte() throws -> UInt8 {
        guard index < data.count else {
            throw SFTPProtocolError.truncatedPacket
        }
        defer { index += 1 }
        return data[index]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard data.count - index >= 4 else {
            throw SFTPProtocolError.truncatedPacket
        }
        let value = (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
        index += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard data.count - index >= 8 else {
            throw SFTPProtocolError.truncatedPacket
        }
        var value: UInt64 = 0
        for _ in 0 ..< 8 {
            value = (value << 8) | UInt64(try readByte())
        }
        return value
    }

    mutating func readData() throws -> Data {
        let length = try readUInt32()
        guard let length = Int(exactly: length), length <= data.count - index else {
            throw SFTPProtocolError.invalidStringLength(length)
        }
        let result = Data(data[index ..< index + length])
        index += length
        return result
    }

    mutating func readString() throws -> String {
        let value = try readData()
        guard let string = String(data: value, encoding: .utf8) else {
            throw SFTPProtocolError.invalidUTF8
        }
        return string
    }

    mutating func readRemaining() throws -> Data {
        let result = Data(data[index...])
        index = data.count
        return result
    }

    mutating func requireAtEnd() throws {
        guard isAtEnd else {
            throw SFTPProtocolError.trailingPayload(data.count - index)
        }
    }
}
