import AppKit
import CoreText
import Foundation

/// Registers the terminal typefaces carried in the app resource bundle.
/// Persisted font values are PostScript names rather than macOS font-family
/// names, so terminal rendering does not depend on the user's installed fonts.
@MainActor
enum BundledTerminalFontRegistry {
    private static var didRegister = false

    static func registerBundledFonts() {
        guard !didRegister else { return }
        defer { didRegister = true }

        for terminalFont in TerminalFont.allCases {
            for fileName in terminalFont.resourceFileNames {
                guard let url = bundledFontURL(fileName) else {
                    assertionFailure("Missing bundled terminal font: \(fileName)")
                    continue
                }

                var registrationError: Unmanaged<CFError>?
                let didRegisterFont = CTFontManagerRegisterFontsForURL(
                    url as CFURL,
                    .process,
                    &registrationError
                )
                if !didRegisterFont {
                    // Re-registering a font in a process can report that it is
                    // already present. The following NSFont lookup remains the
                    // source of truth for rendering.
                    _ = registrationError?.takeRetainedValue()
                }
            }
        }
    }

    static func font(persistedName: String, size: CGFloat) -> NSFont {
        registerBundledFonts()
        let terminalFont = TerminalFont(persistedName: persistedName)
        return NSFont(name: terminalFont.regularPostScriptName, size: size)
            ?? NSFont(name: TerminalFont.preferredDefault.regularPostScriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle.main
#endif
    }

    private static func bundledFontURL(_ fileName: String) -> URL? {
        ["Fonts", "Resources/Fonts", nil].lazy.compactMap { subdirectory in
            resourceBundle.url(
                forResource: fileName,
                withExtension: nil,
                subdirectory: subdirectory
            )
        }.first
    }
}
