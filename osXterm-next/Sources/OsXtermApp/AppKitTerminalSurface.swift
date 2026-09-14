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
    var findRequest: TerminalFindPresentation?
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
            findRequest: findRequest,
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
            findRequest: findRequest,
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
    private var lastFindRequestSequence: UInt64 = 0
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
        findRequest: TerminalFindPresentation?,
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
            lastFindRequestSequence = 0
        }
        self.sessionID = sessionID
        inputEnabled = isInputEnabled
        remoteClipboardEnabled = allowsRemoteClipboard
        terminalView.setAccessibilityLabel(accessibilityLabel)
        terminalView.setAccessibilityHelp(AppText.string(
            "Use the terminal after the SSH connection is ready. Remote clipboard access is disabled unless enabled in Settings.",
            korean: "SSH 연결이 준비된 후 터미널을 사용하세요. 원격 클립보드 접근은 설정에서 허용하기 전까지 비활성화됩니다."
        ))

        let resolvedFont = BundledTerminalFontRegistry.font(
            persistedName: fontName,
            size: fontSize
        )
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

        if let findRequest, findRequest.sequence > lastFindRequestSequence {
            lastFindRequestSequence = findRequest.sequence
            showFindInterface()
        }
    }

    private func showFindInterface() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        terminalView.performTextFinderAction(item)
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

struct TerminalThemeVisualStyle {
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

        case .dracula:
            return makeStyle(
                cacheKey: "dracula",
                foreground: 0xf8f8f2,
                background: 0x282a36,
                selectionForeground: 0xf8f8f2,
                selectionBackground: 0x44475a,
                caret: 0xff79c6,
                ansi: [
                    0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c,
                    0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
                    0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5,
                    0xd6acff, 0xff92df, 0xa4ffff, 0xffffff
                ]
            )

        case .nord:
            return makeStyle(
                cacheKey: "nord",
                foreground: 0xd8dee9,
                background: 0x2e3440,
                selectionForeground: 0xf8fafc,
                selectionBackground: 0x4c566a,
                caret: 0x88c0d0,
                ansi: [
                    0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b,
                    0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                    0x4c566a, 0xd56b76, 0xb5d58e, 0xf0d399,
                    0x8fbcbb, 0xc79bcf, 0x8fdee8, 0xffffff
                ]
            )

        case .gruvboxDark:
            return makeStyle(
                cacheKey: "gruvbox-dark",
                foreground: 0xebdbb2,
                background: 0x282828,
                selectionForeground: 0xebdbb2,
                selectionBackground: 0x504945,
                caret: 0xfabd2f,
                ansi: [
                    0x282828, 0xcc241d, 0x98971a, 0xd79921,
                    0x458588, 0xb16286, 0x689d6a, 0xa89984,
                    0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f,
                    0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2
                ]
            )

        case .gruvboxLight:
            return makeStyle(
                cacheKey: "gruvbox-light",
                foreground: 0x3c3836,
                background: 0xfbf1c7,
                selectionForeground: 0x3c3836,
                selectionBackground: 0xd5c4a1,
                caret: 0xaf3a03,
                ansi: [
                    0x3c3836, 0xcc241d, 0x98971a, 0xd79921,
                    0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
                    0x928374, 0x9d0006, 0x79740e, 0xb57614,
                    0x076678, 0x8f3f71, 0x427b58, 0xfbf1c7
                ]
            )

        case .catppuccinMocha:
            return makeStyle(
                cacheKey: "catppuccin-mocha",
                foreground: 0xcdd6f4,
                background: 0x1e1e2e,
                selectionForeground: 0xcdd6f4,
                selectionBackground: 0x45475a,
                caret: 0xf5e0dc,
                ansi: [
                    0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af,
                    0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
                    0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af,
                    0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8
                ]
            )

        case .catppuccinLatte:
            return makeStyle(
                cacheKey: "catppuccin-latte",
                foreground: 0x4c4f69,
                background: 0xeff1f5,
                selectionForeground: 0x4c4f69,
                selectionBackground: 0xccd0da,
                caret: 0xdc8a78,
                ansi: [
                    0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d,
                    0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
                    0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d,
                    0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc
                ]
            )

        case .tokyoNight:
            return makeStyle(
                cacheKey: "tokyo-night",
                foreground: 0xc0caf5,
                background: 0x1a1b26,
                selectionForeground: 0xc0caf5,
                selectionBackground: 0x33467c,
                caret: 0xc0caf5,
                ansi: [
                    0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68,
                    0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
                    0x414868, 0xf7768e, 0x9ece6a, 0xe0af68,
                    0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5
                ]
            )

        case .tokyoNightStorm:
            return makeStyle(
                cacheKey: "tokyo-night-storm",
                foreground: 0xc0caf5,
                background: 0x24283b,
                selectionForeground: 0xc0caf5,
                selectionBackground: 0x364a82,
                caret: 0x7aa2f7,
                ansi: [
                    0x1d202f, 0xf7768e, 0x9ece6a, 0xe0af68,
                    0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
                    0x414868, 0xf7768e, 0x9ece6a, 0xe0af68,
                    0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5
                ]
            )

        case .monokaiPro:
            return makeStyle(
                cacheKey: "monokai-pro",
                foreground: 0xfcfcfa,
                background: 0x2d2a2e,
                selectionForeground: 0xfcfcfa,
                selectionBackground: 0x5b595c,
                caret: 0xfc9867,
                ansi: [
                    0x403e41, 0xff6188, 0xa9dc76, 0xffd866,
                    0xfc9867, 0xab9df2, 0x78dce8, 0xfcfcfa,
                    0x727072, 0xff6188, 0xa9dc76, 0xffd866,
                    0xfc9867, 0xab9df2, 0x78dce8, 0xfcfcfa
                ]
            )

        case .oneDark:
            return makeStyle(
                cacheKey: "one-dark",
                foreground: 0xabb2bf,
                background: 0x282c34,
                selectionForeground: 0xabb2bf,
                selectionBackground: 0x3e4451,
                caret: 0x528bff,
                ansi: [
                    0x282c34, 0xe06c75, 0x98c379, 0xe5c07b,
                    0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
                    0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b,
                    0x61afef, 0xc678dd, 0x56b6c2, 0xffffff
                ]
            )

        case .githubDark:
            return makeStyle(
                cacheKey: "github-dark",
                foreground: 0xc9d1d9,
                background: 0x0d1117,
                selectionForeground: 0xc9d1d9,
                selectionBackground: 0x264f78,
                caret: 0x58a6ff,
                ansi: [
                    0x484f58, 0xff7b72, 0x3fb950, 0xd29922,
                    0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
                    0x6e7681, 0xf85149, 0x56d364, 0xe3b341,
                    0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xf0f6fc
                ]
            )

        case .githubLight:
            return makeStyle(
                cacheKey: "github-light",
                foreground: 0x24292f,
                background: 0xffffff,
                selectionForeground: 0x24292f,
                selectionBackground: 0xb6e3ff,
                caret: 0x0969da,
                ansi: [
                    0x24292f, 0xcf222e, 0x116329, 0x4d2d00,
                    0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
                    0x57606a, 0xa40e26, 0x1a7f37, 0x633c01,
                    0x218bff, 0x8250df, 0x3192aa, 0x8c959f
                ]
            )

        case .rosePine:
            return makeStyle(
                cacheKey: "rose-pine",
                foreground: 0xe0def4,
                background: 0x191724,
                selectionForeground: 0xe0def4,
                selectionBackground: 0x403d52,
                caret: 0xc4a7e7,
                ansi: [
                    0x6e6a86, 0xeb6f92, 0x9ccfd8, 0xf6c177,
                    0x31748f, 0xc4a7e7, 0xebbcba, 0xe0def4,
                    0x908caa, 0xeb6f92, 0x9ccfd8, 0xf6c177,
                    0x31748f, 0xc4a7e7, 0xeb6f92, 0xe0def4
                ]
            )

        case .everforestDark:
            return makeStyle(
                cacheKey: "everforest-dark",
                foreground: 0xd3c6aa,
                background: 0x2d353b,
                selectionForeground: 0xd3c6aa,
                selectionBackground: 0x475258,
                caret: 0xa7c080,
                ansi: [
                    0x475258, 0xe67e80, 0xa7c080, 0xdbbc7f,
                    0x7fbbb3, 0xd699b6, 0x83c092, 0xd3c6aa,
                    0x859289, 0xe67e80, 0xa7c080, 0xdbbc7f,
                    0x7fbbb3, 0xd699b6, 0x83c092, 0xeae4ca
                ]
            )

        case .ayuMirage:
            return makeStyle(
                cacheKey: "ayu-mirage",
                foreground: 0xcbccc6,
                background: 0x1f2430,
                selectionForeground: 0xcbccc6,
                selectionBackground: 0x33415e,
                caret: 0xffcc66,
                ansi: [
                    0x191e2a, 0xff3333, 0xbae67e, 0xffd173,
                    0x73d0ff, 0xd4bfff, 0x95e6cb, 0xc7c7c7,
                    0x686868, 0xff3333, 0xbae67e, 0xffd173,
                    0x73d0ff, 0xd4bfff, 0x95e6cb, 0xffffff
                ]
            )

        case .kanagawaWave:
            return makeStyle(
                cacheKey: "kanagawa-wave",
                foreground: 0xdcd7ba,
                background: 0x1f1f28,
                selectionForeground: 0xdcd7ba,
                selectionBackground: 0x2d4f67,
                caret: 0xc8c093,
                ansi: [
                    0x16161d, 0xc34043, 0x76946a, 0xc0a36e,
                    0x7e9cd8, 0x957fb8, 0x6a9589, 0xc8c093,
                    0x727169, 0xe82424, 0x98bb6c, 0xe6c384,
                    0x7fb4ca, 0x938aa9, 0x7aa89f, 0xdcd7ba
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
