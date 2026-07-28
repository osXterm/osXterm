import Foundation
import GhosttyVt

public enum GhosttyTerminalEngineError: LocalizedError, Equatable, Sendable {
    case invalidSize(columns: Int, rows: Int)
    case initializationFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidSize(columns, rows):
            "Invalid terminal size: \(columns)x\(rows)."
        case .initializationFailed:
            "Unable to initialize the Ghostty terminal engine."
        }
    }
}

public struct GhosttyTerminalRGB: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum GhosttyTerminalStyledColor: Equatable, Sendable {
    case palette(UInt8)
    case rgb(GhosttyTerminalRGB)
}

/// Number of terminal columns occupied by a rendered cell.
///
/// Ghostty already resolves Unicode width while parsing input. Keeping that
/// value with the styled cell prevents a font's glyph metrics from changing
/// the terminal grid, which is especially important for Powerline symbols.
public enum GhosttyTerminalCellSpan: UInt8, Equatable, Sendable {
    case spacer = 0
    case narrow = 1
    case wide = 2
}

public struct GhosttyTerminalStyledCell: Equatable, Sendable {
    public let text: String
    public let columnSpan: GhosttyTerminalCellSpan
    public let foreground: GhosttyTerminalStyledColor?
    public let background: GhosttyTerminalStyledColor?
    public let bold: Bool
    public let italic: Bool
    public let faint: Bool
    public let inverse: Bool
    public let invisible: Bool
    public let strikethrough: Bool
    public let overline: Bool
    public let underline: Int

    public init(
        text: String,
        columnSpan: GhosttyTerminalCellSpan = .narrow,
        foreground: GhosttyTerminalStyledColor? = nil,
        background: GhosttyTerminalStyledColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        faint: Bool = false,
        inverse: Bool = false,
        invisible: Bool = false,
        strikethrough: Bool = false,
        overline: Bool = false,
        underline: Int = 0
    ) {
        self.text = text
        self.columnSpan = columnSpan
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.faint = faint
        self.inverse = inverse
        self.invisible = invisible
        self.strikethrough = strikethrough
        self.overline = overline
        self.underline = underline
    }

    public var isDefaultBlank: Bool {
        text.isEmpty
            && foreground == nil
            && background == nil
            && !bold
            && !italic
            && !faint
            && !inverse
            && !invisible
            && !strikethrough
            && !overline
            && underline == 0
    }
}

public struct GhosttyTerminalStyledRow: Equatable, Sendable {
    public let cells: [GhosttyTerminalStyledCell]

    public init(cells: [GhosttyTerminalStyledCell]) {
        self.cells = cells
    }
}

public struct GhosttyTerminalStyledScreen: Equatable, Sendable {
    public let rows: [GhosttyTerminalStyledRow]

    public init(rows: [GhosttyTerminalStyledRow]) {
        self.rows = rows
    }

    public init?(encoded data: Data) {
        var reader = BinaryReader(data: data)
        guard reader.readBytes(count: 4) == [0x4d, 0x58, 0x53, 0x43],
              let version = reader.readByte(), version == 1 || version == 2,
              let rowCount = reader.readUInt16()
        else {
            return nil
        }

        var rows: [GhosttyTerminalStyledRow] = []
        rows.reserveCapacity(Int(rowCount))
        for _ in 0 ..< rowCount {
            guard let cellCount = reader.readUInt16() else {
                return nil
            }
            var cells: [GhosttyTerminalStyledCell] = []
            cells.reserveCapacity(Int(cellCount))
            for _ in 0 ..< cellCount {
                guard let textLength = reader.readUInt16(),
                      let textBytes = reader.readBytes(count: Int(textLength)),
                      let styleFlags = reader.readByte(),
                      let colorFlags = reader.readByte(),
                      let underline = reader.readByte()
                else {
                    return nil
                }

                let encodedSpan: UInt8 = version >= 2 ? (reader.readByte() ?? 1) : 1

                let foreground = Self.readColor(
                    kind: colorFlags & 0x03,
                    reader: &reader
                )
                let background = Self.readColor(
                    kind: (colorFlags >> 2) & 0x03,
                    reader: &reader
                )
                guard reader.isValid else {
                    return nil
                }

                cells.append(
                    GhosttyTerminalStyledCell(
                        text: String(decoding: textBytes, as: UTF8.self),
                        columnSpan: GhosttyTerminalCellSpan(rawValue: encodedSpan) ?? .narrow,
                        foreground: foreground,
                        background: background,
                        bold: styleFlags & 0x01 != 0,
                        italic: styleFlags & 0x02 != 0,
                        faint: styleFlags & 0x04 != 0,
                        inverse: styleFlags & 0x08 != 0,
                        invisible: styleFlags & 0x10 != 0,
                        strikethrough: styleFlags & 0x20 != 0,
                        overline: styleFlags & 0x40 != 0,
                        underline: styleFlags & 0x80 == 0 ? 0 : Int(underline)
                    )
                )
            }
            rows.append(GhosttyTerminalStyledRow(cells: cells))
        }

        guard reader.isAtEnd else {
            return nil
        }
        self.rows = rows
    }

    private static func readColor(
        kind: UInt8,
        reader: inout BinaryReader
    ) -> GhosttyTerminalStyledColor? {
        switch kind {
        case 0:
            return nil
        case 1:
            guard let index = reader.readByte() else {
                return nil
            }
            return .palette(index)
        case 2:
            guard let red = reader.readByte(),
                  let green = reader.readByte(),
                  let blue = reader.readByte()
            else {
                return nil
            }
            return .rgb(GhosttyTerminalRGB(red: red, green: green, blue: blue))
        default:
            reader.isValid = false
            return nil
        }
    }
}

public struct GhosttyTerminalCursor: Equatable, Sendable {
    public enum Style: UInt8, Sendable {
        case bar = 0
        case block = 1
        case underline = 2
        case hollowBlock = 3
    }

    public let x: Int
    public let y: Int
    public let visible: Bool
    public let blinking: Bool
    public let hasViewportPosition: Bool
    public let wideTail: Bool
    public let style: Style
    public let color: GhosttyTerminalRGB?

    public init(
        x: Int = 0,
        y: Int = 0,
        visible: Bool = false,
        blinking: Bool = false,
        hasViewportPosition: Bool = false,
        wideTail: Bool = false,
        style: Style = .block,
        color: GhosttyTerminalRGB? = nil
    ) {
        self.x = x
        self.y = y
        self.visible = visible
        self.blinking = blinking
        self.hasViewportPosition = hasViewportPosition
        self.wideTail = wideTail
        self.style = style
        self.color = color
    }

    public static let hidden = GhosttyTerminalCursor()
}

public struct GhosttyTerminalScrollbar: Equatable, Sendable {
    public let totalRows: UInt64
    public let offset: UInt64
    public let viewportRows: UInt64
    public let viewportIsActive: Bool

    public init(
        totalRows: UInt64 = 0,
        offset: UInt64 = 0,
        viewportRows: UInt64 = 0,
        viewportIsActive: Bool = true
    ) {
        self.totalRows = totalRows
        self.offset = offset
        self.viewportRows = viewportRows
        self.viewportIsActive = viewportIsActive
    }

    public static let empty = GhosttyTerminalScrollbar()

    public var isScrollable: Bool {
        totalRows > viewportRows
    }

    public var isAtBottom: Bool {
        offset >= totalRows || viewportRows >= totalRows - offset
    }
}

private struct BinaryReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    var isValid = true

    init(data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool {
        isValid && offset == bytes.count
    }

    mutating func readByte() -> UInt8? {
        guard offset < bytes.count else {
            isValid = false
            return nil
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard let low = readByte(), let high = readByte() else {
            return nil
        }
        return UInt16(low) | (UInt16(high) << 8)
    }

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard count >= 0,
              count <= bytes.count - offset
        else {
            isValid = false
            return nil
        }
        let result = Array(bytes[offset ..< offset + count])
        offset += count
        return result
    }
}

/// The current Ghostty-managed screen state after consuming raw terminal data.
///
/// `styledScreen` is the cell-level projection used by the AppKit renderer.
/// `text` remains a plain-text projection for search and status handling. The
/// source of truth remains libghostty-vt, which owns VT parsing, cursor
/// operations, screen state, and scrollback.
public struct GhosttyTerminalSnapshot: Equatable, Sendable {
    public let text: String
    public let styledScreen: GhosttyTerminalStyledScreen?
    public let cursor: GhosttyTerminalCursor
    public let scrollbar: GhosttyTerminalScrollbar
    public let remotePath: String?
    public let ptyReply: Data

    public init(
        text: String,
        styledScreen: GhosttyTerminalStyledScreen? = nil,
        cursor: GhosttyTerminalCursor = .hidden,
        scrollbar: GhosttyTerminalScrollbar = .empty,
        remotePath: String?,
        ptyReply: Data
    ) {
        self.text = text
        self.styledScreen = styledScreen
        self.cursor = cursor
        self.scrollbar = scrollbar
        self.remotePath = remotePath
        self.ptyReply = ptyReply
    }
}

/// A small ownership-safe Swift facade over the pinned Ghostty VT C API.
///
/// The engine is intentionally used from one UI/session executor. It does not
/// create a PTY or draw pixels: osXterm owns those layers while Ghostty owns
/// terminal emulation state.
public final class GhosttyTerminalEngine {
    private var terminal: OpaquePointer?
    private var latestRemotePath: String?

    public init(
        columns: Int = 120,
        rows: Int = 36,
        maxScrollback: Int = 5_000
    ) throws {
        guard let size = Self.validatedSize(columns: columns, rows: rows) else {
            throw GhosttyTerminalEngineError.invalidSize(columns: columns, rows: rows)
        }

        guard let terminal = osxterm_ghostty_terminal_create(
            size.columns,
            size.rows,
            max(0, maxScrollback)
        ) else {
            throw GhosttyTerminalEngineError.initializationFailed
        }

        self.terminal = terminal
    }

    deinit {
        if let terminal {
            osxterm_ghostty_terminal_destroy(terminal)
        }
    }

    /// Consumes raw PTY output and returns the updated Ghostty screen state.
    public func ingest(_ bytes: Data) -> GhosttyTerminalSnapshot {
        write(bytes)
        return snapshot()
    }

    /// Writes raw PTY output without copying the formatted screen. Callers
    /// that receive a burst of output can render one later snapshot instead of
    /// copying every intermediate cell grid.
    public func write(_ bytes: Data) {
        guard let terminal else {
            return
        }

        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                  !rawBuffer.isEmpty
            else {
                return
            }
            osxterm_ghostty_terminal_write(terminal, baseAddress, rawBuffer.count)
        }
    }

    /// Returns the most recently observed terminal working directory.
    public var remotePath: String? {
        latestRemotePath
    }

    /// Takes device replies generated by terminal emulation without copying
    /// the visible screen.
    public func takePTYReply() -> Data {
        guard let terminal else { return Data() }
        return copiedData(from: terminal, using: osxterm_ghostty_terminal_take_pty_reply)
    }

    @discardableResult
    public func scroll(by rows: Int) -> GhosttyTerminalSnapshot {
        guard let terminal else {
            return GhosttyTerminalSnapshot(
                text: "",
                remotePath: latestRemotePath,
                ptyReply: Data()
            )
        }
        osxterm_ghostty_terminal_scroll_by(terminal, Int64(rows))
        return makeSnapshot(from: terminal)
    }

    @discardableResult
    public func scrollToBottom() -> GhosttyTerminalSnapshot {
        guard let terminal else {
            return GhosttyTerminalSnapshot(
                text: "",
                remotePath: latestRemotePath,
                ptyReply: Data()
            )
        }
        osxterm_ghostty_terminal_scroll_to_bottom(terminal)
        return makeSnapshot(from: terminal)
    }

    /// Moves the viewport without the immediate screen copy used by the
    /// interactive scrollbar path.
    public func scrollToBottomWithoutSnapshot() {
        guard let terminal else { return }
        osxterm_ghostty_terminal_scroll_to_bottom(terminal)
    }

    @discardableResult
    public func scroll(to row: UInt64) -> GhosttyTerminalSnapshot {
        guard let terminal else {
            return GhosttyTerminalSnapshot(
                text: "",
                remotePath: latestRemotePath,
                ptyReply: Data()
            )
        }
        osxterm_ghostty_terminal_scroll_to_row(terminal, row)
        return makeSnapshot(from: terminal)
    }

    /// Applies the same cell geometry to Ghostty that the renderer uses.
    @discardableResult
    public func resize(
        columns: Int,
        rows: Int,
        cellWidthPixels: Int = 0,
        cellHeightPixels: Int = 0
    ) -> Bool {
        guard let terminal,
              let size = Self.validatedSize(columns: columns, rows: rows),
              (0 ... Int(UInt32.max)).contains(cellWidthPixels),
              (0 ... Int(UInt32.max)).contains(cellHeightPixels)
        else {
            return false
        }

        return osxterm_ghostty_terminal_resize(
            terminal,
            size.columns,
            size.rows,
            UInt32(cellWidthPixels),
            UInt32(cellHeightPixels)
        ) != 0
    }

    /// Returns a formatted screen without mutating terminal state.
    public func snapshot() -> GhosttyTerminalSnapshot {
        guard let terminal else {
            return GhosttyTerminalSnapshot(
                text: "",
                remotePath: latestRemotePath,
                ptyReply: Data()
            )
        }

        updateRemotePath(from: terminal)
        return makeSnapshot(from: terminal)
    }

    private func makeSnapshot(from terminal: OpaquePointer) -> GhosttyTerminalSnapshot {
        let metadata = viewportMetadata(from: terminal)
        return GhosttyTerminalSnapshot(
            text: copiedString(from: terminal, using: osxterm_ghostty_terminal_copy_text),
            styledScreen: styledScreen(from: terminal),
            cursor: metadata.map(viewportCursor(from:)) ?? .hidden,
            scrollbar: metadata.map(viewportScrollbar(from:)) ?? .empty,
            remotePath: latestRemotePath,
            ptyReply: copiedData(from: terminal, using: osxterm_ghostty_terminal_take_pty_reply)
        )
    }

    private func styledScreen(from terminal: OpaquePointer) -> GhosttyTerminalStyledScreen? {
        let data = copiedData(
            from: terminal,
            using: osxterm_ghostty_terminal_copy_styled_screen
        )
        return GhosttyTerminalStyledScreen(encoded: data)
    }

    private func viewportMetadata(
        from terminal: OpaquePointer
    ) -> OsXTermGhosttyViewportMetadata? {
        var metadata = OsXTermGhosttyViewportMetadata()
        guard osxterm_ghostty_terminal_copy_viewport_metadata(terminal, &metadata) != 0 else {
            return nil
        }
        return metadata
    }

    private func viewportCursor(
        from metadata: OsXTermGhosttyViewportMetadata
    ) -> GhosttyTerminalCursor {
        let flags = metadata.cursor_flags
        let hasColor = flags & Self.cursorColorFlag != 0
        let color = hasColor
            ? GhosttyTerminalRGB(
                red: metadata.cursor_red,
                green: metadata.cursor_green,
                blue: metadata.cursor_blue
            )
            : nil
        return GhosttyTerminalCursor(
            x: Int(metadata.cursor_x),
            y: Int(metadata.cursor_y),
            visible: flags & Self.cursorVisibleFlag != 0,
            blinking: flags & Self.cursorBlinkingFlag != 0,
            hasViewportPosition: flags & Self.cursorViewportPositionFlag != 0,
            wideTail: flags & Self.cursorWideTailFlag != 0,
            style: GhosttyTerminalCursor.Style(rawValue: metadata.cursor_style) ?? .block,
            color: color
        )
    }

    private func viewportScrollbar(
        from metadata: OsXTermGhosttyViewportMetadata
    ) -> GhosttyTerminalScrollbar {
        GhosttyTerminalScrollbar(
            totalRows: metadata.scroll_total,
            offset: metadata.scroll_offset,
            viewportRows: metadata.scroll_viewport_length,
            viewportIsActive: metadata.cursor_flags & Self.viewportActiveFlag != 0
        )
    }

    private static let cursorVisibleFlag: UInt8 = 1 << 0
    private static let cursorBlinkingFlag: UInt8 = 1 << 1
    private static let cursorViewportPositionFlag: UInt8 = 1 << 2
    private static let cursorWideTailFlag: UInt8 = 1 << 3
    private static let cursorColorFlag: UInt8 = 1 << 4
    private static let viewportActiveFlag: UInt8 = 1 << 5

    private typealias CopyFunction = (
        OpaquePointer?,
        UnsafeMutablePointer<Int>?
    ) -> UnsafeMutablePointer<UInt8>?

    private func copiedString(
        from terminal: OpaquePointer,
        using function: CopyFunction
    ) -> String {
        let data = copiedData(from: terminal, using: function)
        return String(decoding: data, as: UTF8.self)
    }

    private func copiedData(
        from terminal: OpaquePointer,
        using function: CopyFunction
    ) -> Data {
        var length = 0
        guard let buffer = function(terminal, &length), length > 0 else {
            return Data()
        }
        defer {
            osxterm_ghostty_buffer_destroy(buffer)
        }
        return Data(bytes: buffer, count: length)
    }

    private func updateRemotePath(from terminal: OpaquePointer) {
        let rawPath = copiedString(
            from: terminal,
            using: osxterm_ghostty_terminal_copy_working_directory
        )
        guard let normalized = Self.normalizedRemotePath(from: rawPath) else {
            return
        }
        latestRemotePath = normalized
    }

    private static func validatedSize(columns: Int, rows: Int) -> (columns: UInt16, rows: UInt16)? {
        guard
            (1 ... Int(UInt16.max)).contains(columns),
            (1 ... Int(UInt16.max)).contains(rows)
        else {
            return nil
        }
        return (UInt16(columns), UInt16(rows))
    }

    private static func normalizedRemotePath(from rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }

        let path: String
        if let url = URL(string: value), url.scheme?.lowercased() == "file" {
            guard url.user == nil, url.password == nil, url.path.hasPrefix("/") else {
                return nil
            }
            path = url.path
        } else {
            guard value.hasPrefix("/"), !value.contains("://") else {
                return nil
            }
            path = value
        }

        let normalized = URL(fileURLWithPath: path).standardized.path
        return normalized.hasPrefix("/") ? normalized : nil
    }
}
