import AppKit
import Darwin
import SwiftTerm
import SwiftUI

/// SwiftUI bridge for SwiftTerm 1.19.0's AppKit `TerminalView` and
/// `LocalProcess` PTY connection.
///
/// `LocalProcessTerminalView` cannot be used here because its non-overridable
/// OSC 52 clipboard handlers always read and write the system clipboard. This
/// bridge uses the same public SwiftTerm process APIs while retaining a
/// `TerminalViewDelegate` that denies remote clipboard access by default.
/// The core service supplies a shell-free launch request and receives lifecycle
/// evidence before it moves a session to the connected state.
struct AppKitTerminalSurface: NSViewRepresentable {
    var sessionID: UUID
    var launch: TerminalProcessLaunchPresentation?
    var pendingInput: TerminalInputPresentation?
    var fontName: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var themeName: String
    var isInputEnabled: Bool
    var allowsRemoteClipboard: Bool
    var accessibilityLabel: String
    var onInput: (Data) -> Void
    var onResize: (Int, Int) -> Void
    var onProcessStarted: (UUID) -> Void
    var onProcessTerminated: (UUID, Int32?) -> Void
    var onProcessOutput: (UUID, Data) -> Void

    func makeNSView(context _: Context) -> SwiftTermTerminalContainerView {
        let view = SwiftTermTerminalContainerView()
        view.onInput = onInput
        view.onResize = onResize
        view.onProcessStarted = onProcessStarted
        view.onProcessTerminated = onProcessTerminated
        view.onProcessOutput = onProcessOutput
        view.apply(
            sessionID: sessionID,
            launch: launch,
            pendingInput: pendingInput,
            fontName: fontName,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            themeName: themeName,
            isInputEnabled: isInputEnabled,
            allowsRemoteClipboard: allowsRemoteClipboard,
            accessibilityLabel: accessibilityLabel
        )
        return view
    }

    func updateNSView(_ nsView: SwiftTermTerminalContainerView, context _: Context) {
        nsView.onInput = onInput
        nsView.onResize = onResize
        nsView.onProcessStarted = onProcessStarted
        nsView.onProcessTerminated = onProcessTerminated
        nsView.onProcessOutput = onProcessOutput
        nsView.apply(
            sessionID: sessionID,
            launch: launch,
            pendingInput: pendingInput,
            fontName: fontName,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            themeName: themeName,
            isInputEnabled: isInputEnabled,
            allowsRemoteClipboard: allowsRemoteClipboard,
            accessibilityLabel: accessibilityLabel
        )
    }
}

final class SwiftTermTerminalContainerView: NSView, TerminalViewDelegate, LocalProcessDelegate {
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onProcessStarted: ((UUID) -> Void)?
    var onProcessTerminated: ((UUID, Int32?) -> Void)?
    var onProcessOutput: ((UUID, Data) -> Void)?

    private let terminalView: TerminalView
    private var process: LocalProcess?
    private var sessionID: UUID?
    private var activeLaunchID: UUID?
    private var appliedSessionID: UUID?
    private var lastPendingInputSequence: UInt64 = 0
    private var inputEnabled = false
    private var remoteClipboardEnabled = false
    private var appliedFontName = ""
    private var appliedFontSize: CGFloat = 0
    private var appliedLineSpacing: CGFloat = 0
    private var requestedThemeName = TerminalTheme.system.rawValue
    private var appliedThemeCacheKey = ""

    override init(frame frameRect: NSRect) {
        terminalView = TerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()
        terminalView.setAccessibilityRole(.textArea)
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        process?.terminate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTerminalTheme(named: requestedThemeName, force: true)
    }

    func apply(
        sessionID: UUID,
        launch: TerminalProcessLaunchPresentation?,
        pendingInput: TerminalInputPresentation?,
        fontName: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        themeName: String,
        isInputEnabled: Bool,
        allowsRemoteClipboard: Bool,
        accessibilityLabel: String
    ) {
        if appliedSessionID != sessionID {
            appliedSessionID = sessionID
            lastPendingInputSequence = 0
        }
        self.sessionID = sessionID
        inputEnabled = isInputEnabled
        remoteClipboardEnabled = allowsRemoteClipboard
        terminalView.setAccessibilityLabel(accessibilityLabel)
        terminalView.setAccessibilityHelp(AppText.string(
            "Use the terminal after the SSH connection is ready. Remote clipboard access is disabled unless enabled in Settings.",
            korean: "SSH 연결이 준비된 후 터미널을 사용하세요. 원격 클립보드 접근은 설정에서 허용하기 전까지 비활성화됩니다."
        ))

        let resolvedFont = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if appliedFontName != resolvedFont.fontName || appliedFontSize != resolvedFont.pointSize {
            terminalView.font = resolvedFont
            appliedFontName = resolvedFont.fontName
            appliedFontSize = resolvedFont.pointSize
        }
        let normalizedSpacing = max(1, lineSpacing)
        if appliedLineSpacing != normalizedSpacing {
            terminalView.lineSpacing = normalizedSpacing
            appliedLineSpacing = normalizedSpacing
        }
        requestedThemeName = themeName
        applyTerminalTheme(named: themeName, force: false)

        if let launch {
            launchProcessIfNeeded(launch)
        } else if process?.running == true {
            process?.terminate()
            process = nil
            activeLaunchID = nil
        }

        if let pendingInput,
           pendingInput.sequence > lastPendingInputSequence,
           process?.running == true {
            process?.send(data: ArraySlice(pendingInput.data))
            lastPendingInputSequence = pendingInput.sequence
        }
    }

    private func launchProcessIfNeeded(_ launch: TerminalProcessLaunchPresentation) {
        guard activeLaunchID != launch.launchID else { return }
        if process?.running == true {
            process?.terminate()
        }
        let newProcess = LocalProcess(delegate: self)
        process = newProcess
        activeLaunchID = launch.launchID
        newProcess.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment.isEmpty ? nil : launch.environment,
            currentDirectory: launch.currentDirectory
        )
        if newProcess.running {
            onProcessStarted?(launch.launchID)
        }
    }

    private func applyTerminalTheme(named persistedName: String, force: Bool) {
        let style = TerminalThemeVisualStyle.resolve(
            TerminalTheme(persistedName: persistedName),
            appearance: effectiveAppearance
        )
        guard force || appliedThemeCacheKey != style.cacheKey else { return }

        terminalView.nativeForegroundColor = style.foreground
        terminalView.nativeBackgroundColor = style.background
        terminalView.selectedTextForegroundColor = style.selectionForeground
        terminalView.selectedTextBackgroundColor = style.selectionBackground
        terminalView.caretColor = style.caret
        terminalView.caretTextColor = style.caretText
        terminalView.installColors(style.ansiColors)
        appliedThemeCacheKey = style.cacheKey
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) {
        if let process, process.running {
            var size = getWindowSize()
            _ = PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: process.childfd,
                windowSize: &size
            )
        }
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source _: TerminalView, title _: String) {
        // The core service owns persisted titles. OSC titles never modify a
        // connection profile implicitly.
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {
        // Core derives any displayed working directory from its guarded stream.
    }

    func send(source _: TerminalView, data: ArraySlice<UInt8>) {
        guard inputEnabled, !data.isEmpty else { return }
        process?.send(data: data)
        onInput?(Data(data))
    }

    func scrolled(source _: TerminalView, position _: Double) {}

    func requestOpenLink(source _: TerminalView, link: String, params _: [String: String]) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source _: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source _: TerminalView, content: Data) {
        guard remoteClipboardEnabled, let string = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func clipboardRead(source _: TerminalView) -> Data? {
        guard remoteClipboardEnabled,
              let string = NSPasteboard.general.string(forType: .string)
        else {
            return nil
        }
        return Data(string.utf8)
    }

    func iTermContent(source _: TerminalView, content _: ArraySlice<UInt8>) {}

    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}

    // MARK: LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process, let launchID = activeLaunchID else { return }
        onProcessTerminated?(launchID, exitCode)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard !slice.isEmpty, let launchID = activeLaunchID else { return }
        let data = Data(slice)
        onProcessOutput?(launchID, data)
        terminalView.feed(byteArray: slice)
    }

    func getWindowSize() -> winsize {
        let columns = max(1, terminalView.terminal.cols)
        let rows = max(1, terminalView.terminal.rows)
        let cell = terminalView.cellSizeInPixels(source: terminalView.terminal)
        let width = max(0, (cell?.width ?? 0) * columns)
        let height = max(0, (cell?.height ?? 0) * rows)
        return winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: UInt16(clamping: width),
            ws_ypixel: UInt16(clamping: height)
        )
    }
}

private struct TerminalThemeVisualStyle {
    let cacheKey: String
    let foreground: NSColor
    let background: NSColor
    let selectionForeground: NSColor
    let selectionBackground: NSColor
    let caret: NSColor
    let caretText: NSColor
    let ansiColors: [SwiftTerm.Color]

    static func resolve(_ theme: TerminalTheme, appearance: NSAppearance) -> TerminalThemeVisualStyle {
        switch theme {
        case .system:
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let foreground = NSColor.textColor
            let background = NSColor.textBackgroundColor
            return TerminalThemeVisualStyle(
                cacheKey: "system-\(isDark ? "dark" : "light")",
                foreground: foreground,
                background: background,
                selectionForeground: NSColor.selectedTextColor,
                selectionBackground: NSColor.selectedTextBackgroundColor,
                caret: foreground,
                caretText: background,
                ansiColors: palette([
                    0x000000, 0xc23621, 0x25bc24, 0xadad27,
                    0x492ee1, 0xd338d3, 0x33bbc8, 0xcbcccd,
                    0x818383, 0xfc391f, 0x31e722, 0xeaec23,
                    0x5833ff, 0xf935f8, 0x14f0f0, 0xe9ebeb
                ])
            )

        case .midnight:
            return makeStyle(
                cacheKey: "midnight",
                foreground: 0xd8dee9,
                background: 0x101722,
                selectionForeground: 0xf8fafc,
                selectionBackground: 0x345070,
                caret: 0x88c0d0,
                ansi: [
                    0x1d2737, 0xbf616a, 0xa3be8c, 0xebcb8b,
                    0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                    0x4c566a, 0xd56b76, 0xb5d58e, 0xf0d399,
                    0x8fbcbb, 0xc79bcf, 0x8fdee8, 0xffffff
                ]
            )

        case .solarizedDark:
            return makeStyle(
                cacheKey: "solarized-dark",
                foreground: 0x839496,
                background: 0x002b36,
                selectionForeground: 0xfdf6e3,
                selectionBackground: 0x265b67,
                caret: 0x2aa198,
                ansi: [
                    0x073642, 0xdc322f, 0x859900, 0xb58900,
                    0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                    0x002b36, 0xcb4b16, 0x586e75, 0x657b83,
                    0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3
                ]
            )

        case .solarizedLight:
            return makeStyle(
                cacheKey: "solarized-light",
                foreground: 0x657b83,
                background: 0xfdf6e3,
                selectionForeground: 0xfdf6e3,
                selectionBackground: 0x2aa198,
                caret: 0x268bd2,
                ansi: [
                    0x073642, 0xdc322f, 0x859900, 0xb58900,
                    0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                    0x002b36, 0xcb4b16, 0x586e75, 0x657b83,
                    0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3
                ]
            )
        }
    }

    private static func makeStyle(
        cacheKey: String,
        foreground: UInt32,
        background: UInt32,
        selectionForeground: UInt32,
        selectionBackground: UInt32,
        caret: UInt32,
        ansi: [UInt32]
    ) -> TerminalThemeVisualStyle {
        TerminalThemeVisualStyle(
            cacheKey: cacheKey,
            foreground: color(foreground),
            background: color(background),
            selectionForeground: color(selectionForeground),
            selectionBackground: color(selectionBackground),
            caret: color(caret),
            caretText: color(background),
            ansiColors: palette(ansi)
        )
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    private static func palette(_ colors: [UInt32]) -> [SwiftTerm.Color] {
        colors.map { color in
            SwiftTerm.Color(
                red8: UInt16((color >> 16) & 0xff),
                green8: UInt16((color >> 8) & 0xff),
                blue8: UInt16(color & 0xff)
            )
        }
    }
}
