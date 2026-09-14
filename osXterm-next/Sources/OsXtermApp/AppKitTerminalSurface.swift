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

    func apply(
        sessionID: UUID,
        launch: TerminalProcessLaunchPresentation?,
        pendingInput: TerminalInputPresentation?,
        fontName: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
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
