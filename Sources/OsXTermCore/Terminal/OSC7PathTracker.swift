import Foundation

/// A validated working-directory update carried by terminal OSC 7.
public struct OSC7PathUpdate: Equatable, Sendable {
    public let url: URL
    public let host: String?
    public let path: String

    public init(url: URL, host: String?, path: String) {
        self.url = url
        self.host = host
        self.path = path
    }
}

/// Incrementally extracts OSC 7 `file://host/path` working-directory reports.
///
/// Both 7-bit (`ESC ]` and `ESC \`) and 8-bit (OSC and ST) control forms are
/// supported. The parser is intentionally independent of terminal chunk
/// boundaries and applies a payload limit so malformed output cannot grow its
/// buffer without bound.
public struct OSC7PathTracker: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case collecting
        case collectingEscape
        case discarding
        case discardingEscape
    }

    private static let escapeByte: UInt8 = 0x1B
    private static let bellByte: UInt8 = 0x07
    private static let oscByte: UInt8 = 0x9D
    private static let stringTerminatorByte: UInt8 = 0x9C

    private var state: State = .ground
    private var payload: [UInt8] = []
    public let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = 8_192) {
        self.maximumPayloadBytes = max(3, maximumPayloadBytes)
        payload.reserveCapacity(min(self.maximumPayloadBytes, 256))
    }

    public mutating func reset() {
        state = .ground
        payload.removeAll(keepingCapacity: true)
    }

    public mutating func ingest(_ data: Data) -> [OSC7PathUpdate] {
        ingest(data.lazy)
    }

    public mutating func ingest<S: Sequence>(_ bytes: S) -> [OSC7PathUpdate]
    where S.Element == UInt8 {
        var updates: [OSC7PathUpdate] = []

        for byte in bytes {
            switch state {
            case .ground:
                if byte == Self.escapeByte {
                    state = .escape
                } else if byte == Self.oscByte {
                    beginPayload()
                }

            case .escape:
                if byte == UInt8(ascii: "]") {
                    beginPayload()
                } else if byte == Self.escapeByte {
                    state = .escape
                } else if byte == Self.oscByte {
                    beginPayload()
                } else {
                    state = .ground
                }

            case .collecting:
                if byte == Self.bellByte || byte == Self.stringTerminatorByte {
                    if let update = finishPayload() {
                        updates.append(update)
                    }
                } else if byte == Self.escapeByte {
                    state = .collectingEscape
                } else {
                    appendOrDiscard(byte)
                }

            case .collectingEscape:
                if byte == UInt8(ascii: "\\") {
                    if let update = finishPayload() {
                        updates.append(update)
                    }
                } else if byte == Self.bellByte || byte == Self.stringTerminatorByte {
                    appendOrDiscard(Self.escapeByte)
                    if case .discarding = state {
                        reset()
                    } else if let update = finishPayload() {
                        updates.append(update)
                    }
                } else if byte == Self.escapeByte {
                    appendOrDiscard(Self.escapeByte)
                    if case .collecting = state {
                        state = .collectingEscape
                    } else if case .discarding = state {
                        state = .discardingEscape
                    }
                } else {
                    appendOrDiscard(Self.escapeByte)
                    if case .collecting = state {
                        appendOrDiscard(byte)
                    } else if case .discarding = state {
                        state = .discarding
                    }
                }

            case .discarding:
                if byte == Self.bellByte || byte == Self.stringTerminatorByte {
                    reset()
                } else if byte == Self.escapeByte {
                    state = .discardingEscape
                }

            case .discardingEscape:
                if byte == UInt8(ascii: "\\")
                    || byte == Self.bellByte
                    || byte == Self.stringTerminatorByte
                {
                    reset()
                } else if byte != Self.escapeByte {
                    state = .discarding
                }
            }
        }

        return updates
    }

    private mutating func beginPayload() {
        payload.removeAll(keepingCapacity: true)
        state = .collecting
    }

    private mutating func appendOrDiscard(_ byte: UInt8) {
        guard payload.count < maximumPayloadBytes else {
            payload.removeAll(keepingCapacity: true)
            state = .discarding
            return
        }
        payload.append(byte)
        state = .collecting
    }

    private mutating func finishPayload() -> OSC7PathUpdate? {
        let completedPayload = payload
        reset()

        guard completedPayload.starts(with: [UInt8(ascii: "7"), UInt8(ascii: ";")]) else {
            return nil
        }

        let uriBytes = completedPayload.dropFirst(2)
        guard let uri = String(bytes: uriBytes, encoding: .utf8),
              let url = URL(string: uri),
              url.scheme?.lowercased() == "file",
              url.user == nil,
              url.password == nil,
              url.path.hasPrefix("/"),
              !url.path.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            return nil
        }

        return OSC7PathUpdate(url: url, host: url.host, path: url.path)
    }
}
