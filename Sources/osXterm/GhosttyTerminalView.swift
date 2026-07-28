@preconcurrency import AppKit
import CoreText
import OsXTermCore
import SwiftUI

struct GhosttyTerminalView: NSViewRepresentable {
    @Environment(\.ghosttyTerminalPalette) private var palette
    @Environment(\.ghosttyTerminalFontConfiguration) private var fontConfiguration
    @ObservedObject var session: TerminalSessionViewModel
    var fontSize: CGFloat = 13

    func makeNSView(context: Context) -> GhosttyTerminalHostView {
        let host = GhosttyTerminalHostView()
        host.updatePalette(palette)
        host.updateFontConfiguration(fontConfiguration)
        host.updateFontSize(fontSize)
        configure(host)
        return host
    }

    func updateNSView(_ host: GhosttyTerminalHostView, context: Context) {
        host.updatePalette(palette)
        host.updateFontConfiguration(fontConfiguration)
        host.updateFontSize(fontSize)
        configure(host)
        host.updateSnapshot(
            styledScreen: session.styledScreen,
            cursor: session.cursor,
            scrollbar: session.scrollbar
        )
    }

    private func configure(_ host: GhosttyTerminalHostView) {
        host.isInputEnabled = session.isTerminalInputReady
        host.onInput = { [weak session] bytes in
            Task { @MainActor in await session?.send(data: bytes) }
        }
        host.onScroll = { [weak session] rows in
            Task { @MainActor in session?.scrollTerminal(by: rows) }
        }
        host.onScrollTo = { [weak session] offset in
            Task { @MainActor in session?.scrollTerminal(to: offset) }
        }
        host.onResize = { [weak session] columns, rows, cellWidth, cellHeight in
            Task { @MainActor in
                await session?.resizeTerminal(
                    columns: columns,
                    rows: rows,
                    cellWidthPixels: cellWidth,
                    cellHeightPixels: cellHeight
                )
            }
        }
    }
}

struct TerminalGridMetrics {
    let font: NSFont
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let inset: CGFloat
    let columns: Int
    let rows: Int

    init(size: NSSize, font: NSFont, inset: CGFloat = 14) {
        self.font = font
        self.inset = inset
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        cellWidth = max(1, ceil(("W" as NSString).size(withAttributes: attributes).width))
        lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        columns = max(20, Int(floor(max(1, size.width - inset * 2) / cellWidth)))
        rows = max(4, Int(floor(max(1, size.height - inset * 2) / lineHeight)))
    }

    func cellRect(column: Int, row: Int, in size: NSSize) -> NSRect {
        NSRect(
            x: inset + CGFloat(column) * cellWidth,
            y: size.height - inset - CGFloat(row + 1) * lineHeight,
            width: cellWidth,
            height: lineHeight
        )
    }

    func cell(at point: NSPoint, in size: NSSize) -> (column: Int, row: Int) {
        let column = max(0, min(columns - 1, Int((point.x - inset) / cellWidth)))
        let row = max(0, min(rows - 1, Int((size.height - inset - point.y) / lineHeight)))
        return (column, row)
    }
}

final class GhosttyTerminalHostView: NSView {
    var onInput: ((Data) -> Void)? { didSet { canvas.onInput = onInput } }
    var onResize: ((Int, Int, Int, Int) -> Void)?
    var onScroll: ((Int) -> Void)? { didSet { canvas.onScroll = onScroll } }
    var onScrollTo: ((UInt64) -> Void)? { didSet { canvas.onScrollTo = onScrollTo } }
    var isInputEnabled = false { didSet { canvas.isTerminalInputEnabled = isInputEnabled } }

    private let canvas = GhosttyTerminalCanvasView()
    private let scrollBar = NSScroller()
    private var latestScrollbar = GhosttyTerminalScrollbar.empty
    private var lastGridSize: (columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)?
    private var hasRequestedInitialFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        scrollBar.translatesAutoresizingMaskIntoConstraints = false
        scrollBar.scrollerStyle = .overlay
        scrollBar.controlSize = .small
        scrollBar.isHidden = true
        scrollBar.target = self
        scrollBar.action = #selector(scrollBarAction(_:))
        addSubview(canvas)
        addSubview(scrollBar)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            scrollBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scrollBar.widthAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(canvas) == true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestInitialFocusIfNeeded()
    }

    override func layout() {
        super.layout()
        reportGridSizeIfNeeded()
    }

    func updatePalette(_ palette: GhosttyTerminalPalette) {
        if canvas.updatePalette(palette) {
            layer?.backgroundColor = palette.nsBackground.cgColor
        }
    }

    func updateFontConfiguration(_ configuration: GhosttyFontConfiguration) {
        canvas.updateFontConfiguration(configuration)
        needsLayout = true
        needsDisplay = true
    }

    func updateFontSize(_ fontSize: CGFloat) {
        canvas.updateFontSize(fontSize)
        needsLayout = true
        needsDisplay = true
    }

    func updateSnapshot(
        styledScreen: GhosttyTerminalStyledScreen?,
        cursor: GhosttyTerminalCursor,
        scrollbar: GhosttyTerminalScrollbar
    ) {
        latestScrollbar = scrollbar
        canvas.updateSnapshot(styledScreen: styledScreen, cursor: cursor, scrollbar: scrollbar)
        requestInitialFocusIfNeeded()
        scrollBar.isHidden = !scrollbar.isScrollable
        guard scrollbar.isScrollable else {
            scrollBar.doubleValue = 1
            scrollBar.knobProportion = 1
            return
        }
        let maxOffset = max(1, scrollbar.totalRows - scrollbar.viewportRows)
        scrollBar.knobProportion = min(1, CGFloat(scrollbar.viewportRows) / CGFloat(max(1, scrollbar.totalRows)))
        scrollBar.doubleValue = min(1, Double(scrollbar.offset) / Double(maxOffset))
    }

    @objc private func scrollBarAction(_ sender: NSScroller) {
        guard latestScrollbar.isScrollable else { return }
        let maxOffset = latestScrollbar.totalRows - latestScrollbar.viewportRows
        let requested = UInt64(max(0, min(1, sender.doubleValue)) * Double(maxOffset))
        onScrollTo?(requested)
    }

    private func reportGridSizeIfNeeded() {
        let metrics = TerminalGridMetrics(size: bounds.size, font: canvas.terminalFont)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 1
        let cellWidth = max(1, Int((metrics.cellWidth * scale).rounded(.up)))
        let cellHeight = max(1, Int((metrics.lineHeight * scale).rounded(.up)))
        guard lastGridSize?.columns != metrics.columns
            || lastGridSize?.rows != metrics.rows
            || lastGridSize?.cellWidth != cellWidth
            || lastGridSize?.cellHeight != cellHeight
        else { return }
        lastGridSize = (metrics.columns, metrics.rows, cellWidth, cellHeight)
        onResize?(
            metrics.columns,
            metrics.rows,
            cellWidth,
            cellHeight
        )
    }

    private func requestInitialFocusIfNeeded() {
        guard isInputEnabled, window != nil, !hasRequestedInitialFocus else { return }
        hasRequestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInputEnabled else { return }
            self.window?.makeFirstResponder(self.canvas)
        }
    }
}

private final class GhosttyTerminalCanvasView: NSView, @preconcurrency NSTextInputClient {
    var onInput: ((Data) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onScrollTo: ((UInt64) -> Void)?
    var isTerminalInputEnabled = false

    private var palette = GhosttyTerminalTheme.ghosttyDark.palette
    private var fontConfiguration = GhosttyFontConfiguration.defaultValue
    fileprivate private(set) var terminalFont = TerminalAppearance.nsTerminalFont(
        configuration: .defaultValue
    )
    private var screen: GhosttyTerminalStyledScreen?
    private var cursor = GhosttyTerminalCursor.hidden
    private var cursorBlinkTimer: Timer?
    private var cursorBlinkPhase = true
    private var scrollbar = GhosttyTerminalScrollbar.empty
    private var scrollAccumulator: CGFloat = 0
    private var markedText = NSMutableAttributedString()
    private var selectionStart: (column: Int, row: Int)?
    private var selectionEnd: (column: Int, row: Int)?
    private var fontCache: [FontCacheKey: NSFont] = [:]

    private struct FontCacheKey: Hashable {
        let scalar: UInt32?
        let pointSize: Int
        let bold: Bool
        let italic: Bool
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = palette.nsBackground.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cursorBlinkTimer?.invalidate()
            cursorBlinkTimer = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @discardableResult
    func updatePalette(_ palette: GhosttyTerminalPalette) -> Bool {
        guard !paletteMatches(palette) else { return false }
        self.palette = palette
        layer?.backgroundColor = palette.nsBackground.cgColor
        needsDisplay = true
        return true
    }

    func updateFontConfiguration(_ configuration: GhosttyFontConfiguration) {
        guard fontConfiguration != configuration else { return }
        fontConfiguration = configuration
        fontCache.removeAll(keepingCapacity: true)
        terminalFont = TerminalAppearance.nsTerminalFont(
            size: terminalFont.pointSize,
            configuration: configuration
        )
        needsDisplay = true
        superview?.needsLayout = true
    }

    func updateFontSize(_ fontSize: CGFloat) {
        let normalizedSize = min(max(fontSize, 10), 24)
        guard abs(terminalFont.pointSize - normalizedSize) > 0.01 else { return }
        terminalFont = TerminalAppearance.nsTerminalFont(
            size: normalizedSize,
            configuration: fontConfiguration
        )
        fontCache.removeAll(keepingCapacity: true)
        needsDisplay = true
        superview?.needsLayout = true
    }

    func updateSnapshot(
        styledScreen: GhosttyTerminalStyledScreen?,
        cursor: GhosttyTerminalCursor,
        scrollbar: GhosttyTerminalScrollbar
    ) {
        self.screen = styledScreen
        self.cursor = cursor
        updateCursorBlink(for: cursor)
        self.scrollbar = scrollbar
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let metrics = gridMetrics
        let point = convert(event.locationInWindow, from: nil)
        selectionStart = metrics.cell(at: point, in: bounds.size)
        selectionEnd = selectionStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let metrics = gridMetrics
        let point = convert(event.locationInWindow, from: nil)
        selectionEnd = metrics.cell(at: point, in: bounds.size)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let start = selectionStart, let end = selectionEnd,
           start.column == end.column, start.row == end.row
        {
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let pixelsPerRow: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 1
        scrollAccumulator += -event.scrollingDeltaY / pixelsPerRow
        let rows = Int(scrollAccumulator.rounded(.towardZero))
        scrollAccumulator -= CGFloat(rows)
        if rows != 0 { onScroll?(rows) }
    }

    override func keyDown(with event: NSEvent) {
        guard isTerminalInputEnabled else { NSSound.beep(); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copySelection(); return
            case "v": paste(nil); return
            default: break
            }
        }

        let specialKey = [36, 48, 51, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(event.keyCode)
        if specialKey || modifiers.contains(.control) || modifiers.contains(.option) {
            if let bytes = terminalBytes(for: event) {
                restartCursorBlink()
                onInput?(bytes)
            }
            return
        }
        interpretKeyEvents([event])
    }

    func paste(_ sender: Any?) {
        guard isTerminalInputEnabled,
              let string = NSPasteboard.general.string(forType: .string),
              !string.isEmpty
        else { return }
        restartCursorBlink()
        onInput?(Data(string.utf8))
    }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = gridMetrics
        palette.nsBackground.setFill()
        bounds.fill()
        guard let screen else {
            drawMarkedText(metrics: metrics)
            return
        }

        drawSelectionBackground(metrics: metrics)
        for rowIndex in 0 ..< min(metrics.rows, screen.rows.count) {
            let row = screen.rows[rowIndex]
            for columnIndex in 0 ..< min(metrics.columns, row.cells.count) {
                let cell = row.cells[columnIndex]
                let rect = metrics.cellRect(column: columnIndex, row: rowIndex, in: bounds.size)
                draw(cell: cell, in: rect, row: rowIndex, metrics: metrics)
            }
        }

        if scrollbar.viewportIsActive,
           cursor.visible,
           cursorBlinkPhase,
           cursor.hasViewportPosition,
           !cursor.wideTail
        {
            drawCursor(metrics: metrics)
        }
        drawMarkedText(metrics: metrics)
    }

    private func draw(cell: GhosttyTerminalStyledCell, in rect: NSRect, row: Int, metrics: TerminalGridMetrics) {
        var foreground = color(for: cell.foreground) ?? palette.nsText
        var background = color(for: cell.background)
        let span = max(1, Int(cell.columnSpan.rawValue))
        let drawRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: min(bounds.maxX - rect.minX, metrics.cellWidth * CGFloat(span)),
            height: rect.height
        )
        if cell.inverse {
            let swap = background ?? palette.nsBackground
            background = foreground
            foreground = swap
        }
        if let background { background.setFill(); drawRect.fill() }
        if cell.invisible { foreground = background ?? palette.nsBackground }
        if cell.faint { foreground = foreground.withAlphaComponent(0.65) }
        guard !cell.text.isEmpty else { return }

        let font = terminalFont
        let styledFont = fontFor(
            base: font,
            bold: cell.bold,
            italic: cell.italic,
            text: cell.text
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: styledFont,
            .foregroundColor: foreground,
            .underlineStyle: cell.underline == 2 ? NSUnderlineStyle.double.rawValue : (cell.underline > 0 ? NSUnderlineStyle.single.rawValue : 0),
            .strikethroughStyle: cell.strikethrough ? NSUnderlineStyle.single.rawValue : 0
        ]
        let attributedText = NSAttributedString(string: cell.text, attributes: attributes)
        NSGraphicsContext.current?.saveGraphicsState()
        // Ghostty backgrounds are defined per grid cell. Clip the foreground
        // to that same rectangle so a tall fallback font cannot cover the
        // prompt or command row above it.
        NSRect(
            x: rect.minX + 0.5,
            y: rect.minY,
            width: max(1, drawRect.width - 1),
            height: rect.height
        ).clip()
        drawTerminalText(attributedText, in: drawRect, fallbackFont: styledFont)
        NSGraphicsContext.current?.restoreGraphicsState()
        if cell.overline {
            foreground.setFill()
            NSRect(x: drawRect.minX, y: drawRect.maxY - 1, width: drawRect.width, height: 1).fill()
        }
    }

    private func drawCursor(metrics: TerminalGridMetrics) {
        let rect = metrics.cellRect(column: cursor.x, row: cursor.y, in: bounds.size)
        let color = cursor.color.map(nsColor) ?? palette.insertionPoint
        switch cursor.style {
        case .bar:
            color.setFill(); NSRect(x: rect.minX, y: rect.minY, width: max(2, rect.width * 0.12), height: rect.height).fill()
        case .underline:
            color.setFill(); NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(2, rect.height * 0.12)).fill()
        case .hollowBlock:
            color.setStroke(); let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)); path.lineWidth = 2; path.stroke()
        case .block:
            color.withAlphaComponent(0.82).setFill(); rect.fill()
        }
    }

    private func drawSelectionBackground(metrics: TerminalGridMetrics) {
        guard let start = selectionStart, let end = selectionEnd, let screen else { return }
        let lower = start.row < end.row || (start.row == end.row && start.column <= end.column) ? start : end
        let upper = lower == start ? end : start
        palette.selectionBackground.setFill()
        for row in lower.row ... upper.row {
            let first = row == lower.row ? lower.column : 0
            let last = row == upper.row ? upper.column : metrics.columns - 1
            guard row < screen.rows.count, first <= last else { continue }
            NSRect(
                x: metrics.cellRect(column: first, row: row, in: bounds.size).minX,
                y: metrics.cellRect(column: first, row: row, in: bounds.size).minY,
                width: CGFloat(last - first + 1) * metrics.cellWidth,
                height: metrics.lineHeight
            ).fill()
        }
    }

    private func drawMarkedText(metrics: TerminalGridMetrics) {
        guard markedText.length > 0 else { return }
        let rect = metrics.cellRect(column: cursor.x, row: cursor.y, in: bounds.size)
        let font = markedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            ?? terminalFont
        drawTerminalText(markedText, in: rect, fallbackFont: font)
    }

    /// Aligns every glyph from one font to one terminal baseline. This keeps
    /// normal characters, box-drawing characters, and fallback icon fonts on
    /// the same row while leaving Ghostty's cell backgrounds untouched.
    private func drawTerminalText(
        _ text: NSAttributedString,
        in rect: NSRect,
        fallbackFont: NSFont
    ) {
        guard let graphicsContext = NSGraphicsContext.current else { return }
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        if ascent <= 0 && descent <= 0 {
            ascent = fallbackFont.ascender
            descent = -fallbackFont.descender
        }

        graphicsContext.saveGraphicsState()
        rect.clip()
        let context = graphicsContext.cgContext
        context.textPosition = CGPoint(
            x: rect.minX,
            y: rect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
        graphicsContext.restoreGraphicsState()
    }

    private var gridMetrics: TerminalGridMetrics {
        TerminalGridMetrics(size: bounds.size, font: terminalFont)
    }

    private func color(for styledColor: GhosttyTerminalStyledColor?) -> NSColor? {
        guard let styledColor else { return nil }
        switch styledColor {
        case let .palette(index): return palette.color(at: index)
        case let .rgb(rgb): return nsColor(rgb)
        }
    }

    private func updateCursorBlink(for cursor: GhosttyTerminalCursor) {
        guard cursor.blinking, cursor.visible else {
            cursorBlinkTimer?.invalidate()
            cursorBlinkTimer = nil
            cursorBlinkPhase = true
            return
        }
        guard cursorBlinkTimer == nil else { return }
        cursorBlinkPhase = true
        let timer = Timer(
            timeInterval: 0.6,
            target: self,
            selector: #selector(toggleCursorBlink),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        cursorBlinkTimer = timer
    }

    private func restartCursorBlink() {
        guard cursor.blinking, cursor.visible else { return }
        cursorBlinkPhase = true
        needsDisplay = true
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        updateCursorBlink(for: cursor)
    }

    @objc private func toggleCursorBlink() {
        cursorBlinkPhase.toggle()
        needsDisplay = true
    }

    private func fontFor(base: NSFont, bold: Bool, italic: Bool, text: String) -> NSFont {
        let key = FontCacheKey(
            scalar: text.unicodeScalars.first?.value,
            pointSize: Int((base.pointSize * 100).rounded()),
            bold: bold,
            italic: italic
        )
        if let cached = fontCache[key] {
            return cached
        }

        let configured = TerminalAppearance.nsTerminalGlyphFont(
            size: base.pointSize,
            configuration: fontConfiguration,
            bold: bold,
            italic: italic,
            text: text
        )
        fontCache[key] = configured
        return configured
    }

    private func paletteMatches(_ candidate: GhosttyTerminalPalette) -> Bool {
        guard palette.nsBackground.isEqual(candidate.nsBackground),
              palette.nsText.isEqual(candidate.nsText),
              palette.insertionPoint.isEqual(candidate.insertionPoint),
              palette.selectionBackground.isEqual(candidate.selectionBackground),
              palette.selectionForeground.isEqual(candidate.selectionForeground),
              palette.ansi.count == candidate.ansi.count
        else {
            return false
        }
        return zip(palette.ansi, candidate.ansi).allSatisfy { lhs, rhs in
            lhs.isEqual(rhs)
        }
    }

    private func nsColor(_ rgb: GhosttyTerminalRGB) -> NSColor {
        NSColor(calibratedRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    private func copySelection() {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func selectedText() -> String? {
        guard let start = selectionStart, let end = selectionEnd, let screen else { return nil }
        let lower = start.row < end.row || (start.row == end.row && start.column <= end.column) ? start : end
        let upper = lower == start ? end : start
        var lines: [String] = []
        for rowIndex in lower.row ... upper.row {
            guard rowIndex < screen.rows.count else { continue }
            let row = screen.rows[rowIndex]
            let first = rowIndex == lower.row ? lower.column : 0
            let last = rowIndex == upper.row ? upper.column : row.cells.count - 1
            guard first <= last, first < row.cells.count else { continue }
            lines.append(row.cells[first ... min(last, row.cells.count - 1)].map { $0.text.isEmpty ? " " : $0.text }.joined().trimmingCharacters(in: .whitespaces))
        }
        return lines.joined(separator: "\n")
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.length) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let value = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: value) }
        else { markedText = NSMutableAttributedString(string: String(describing: string)) }
        needsDisplay = true
    }
    func unmarkText() { markedText = NSMutableAttributedString(); needsDisplay = true }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.font, .foregroundColor, .backgroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = gridMetrics.cellRect(column: cursor.x, row: cursor.y, in: bounds.size)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isTerminalInputEnabled else { return }
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        guard !text.isEmpty else { return }
        restartCursorBlink()
        onInput?(Data(text.utf8))
        unmarkText()
    }
    override func doCommand(by selector: Selector) {}

    private func terminalBytes(for event: NSEvent) -> Data? {
        switch event.keyCode {
        case 36, 76: return Data("\r".utf8)
        case 48: return Data("\t".utf8)
        case 51: return Data([0x7F])
        case 117: return Data("\u{001B}[3~".utf8)
        case 53: return Data([0x1B])
        case 123: return Data("\u{001B}[D".utf8)
        case 124: return Data("\u{001B}[C".utf8)
        case 125: return Data("\u{001B}[B".utf8)
        case 126: return Data("\u{001B}[A".utf8)
        case 115: return Data("\u{001B}[H".utf8)
        case 119: return Data("\u{001B}[F".utf8)
        case 116: return Data("\u{001B}[5~".utf8)
        case 121: return Data("\u{001B}[6~".utf8)
        default:
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first, scalar.value <= 0x7F {
                return Data([UInt8(scalar.value & 0x1F)])
            }
            guard let characters = event.characters, !characters.isEmpty else { return nil }
            var bytes = Data()
            if modifiers.contains(.option) { bytes.append(0x1B) }
            bytes.append(contentsOf: characters.utf8)
            return bytes
        }
    }
}
