import AppKit
import CoreText
import OsXTermCore
import SwiftUI

/// A terminal-only palette. This is intentionally independent from the
/// osXterm window and sidebar appearance.
struct GhosttyTerminalTheme: Identifiable {
    let definition: GhosttyThemeDefinition

    init(definition: GhosttyThemeDefinition) {
        self.definition = definition
    }

    var id: String { definition.id }
    var title: String { definition.name }
    var source: String { definition.source }
    var palette: GhosttyTerminalPalette { GhosttyTerminalPalette(colors: definition.colors) }

    static let ghosttyDark = GhosttyTerminalTheme(
        definition: GhosttyThemeDefinition(
            id: GhosttyThemeCatalog.namedThemeID("Ghostty Dark"),
            name: "Ghostty Dark",
            source: "osXterm fallback",
            colors: .ghosttyDark
        )
    )
}

struct GhosttyTerminalPalette {
    let background: Color
    let text: Color
    let nsBackground: NSColor
    let nsText: NSColor
    let insertionPoint: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor
    let ansi: [NSColor]

    init(colors: GhosttyThemeColors) {
        let fallback = GhosttyThemeColors.ghosttyDark
        let background = Self.nsColor(
            hex: colors.background ?? fallback.background!,
            fallback: NSColor(red: 0.027, green: 0.031, blue: 0.047, alpha: 1)
        )
        let text = Self.nsColor(
            hex: colors.foreground ?? fallback.foreground!,
            fallback: NSColor(red: 0.88, green: 0.90, blue: 0.95, alpha: 1)
        )
        let cursor = Self.nsColor(
            hex: colors.cursorColor ?? colors.foreground ?? fallback.foreground!,
            fallback: text
        )
        let selectionBackground = Self.nsColor(
            hex: colors.selectionBackground ?? fallback.selectionBackground!,
            fallback: background.blended(withFraction: 0.2, of: .white) ?? background
        )
        let selectionForeground = Self.nsColor(
            hex: colors.selectionForeground ?? colors.foreground ?? fallback.foreground!,
            fallback: text
        )

        self.background = Color(nsColor: background)
        self.text = Color(nsColor: text)
        self.nsBackground = background
        self.nsText = text
        self.insertionPoint = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground

        let ansiFallbacks = [
            "#000000", "#cc0000", "#4e9a06", "#c4a000",
            "#3465a4", "#75507b", "#06989a", "#d3d7cf",
            "#555753", "#ef2929", "#8ae234", "#fce94f",
            "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"
        ]
        var fallbackANSI = ansiFallbacks.map { hex in
            Self.nsColor(hex: hex, fallback: text)
        }
        let cubeLevels = [0, 95, 135, 175, 215, 255]
        for red in cubeLevels {
            for green in cubeLevels {
                for blue in cubeLevels {
                    fallbackANSI.append(
                        NSColor(
                            calibratedRed: CGFloat(red) / 255,
                            green: CGFloat(green) / 255,
                            blue: CGFloat(blue) / 255,
                            alpha: 1
                        )
                    )
                }
            }
        }
        for index in 0 ..< 24 {
            let component = CGFloat(8 + index * 10) / 255
            fallbackANSI.append(
                NSColor(
                    calibratedRed: component,
                    green: component,
                    blue: component,
                    alpha: 1
                )
            )
        }
        ansi = fallbackANSI.enumerated().map { index, fallback in
            Self.nsColor(
                hex: colors.palette[index] ?? "",
                fallback: fallback
            )
        }
    }

    func color(at index: UInt8) -> NSColor {
        ansi.indices.contains(Int(index)) ? ansi[Int(index)] : nsText
    }

    private static func nsColor(hex: String, fallback: NSColor) -> NSColor {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(digits, radix: 16)
        else {
            return fallback
        }

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        if digits.count == 8 {
            red = (value >> 24) & 0xff
            green = (value >> 16) & 0xff
            blue = (value >> 8) & 0xff
            alpha = value & 0xff
        } else {
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
            alpha = 0xff
        }
        return NSColor(
            calibratedRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}

extension EnvironmentValues {
    var ghosttyTerminalPalette: GhosttyTerminalPalette {
        get { self[GhosttyTerminalPaletteKey.self] }
        set { self[GhosttyTerminalPaletteKey.self] = newValue }
    }
}

private struct GhosttyTerminalPaletteKey: EnvironmentKey {
    static let defaultValue = GhosttyTerminalTheme.ghosttyDark.palette
}

extension EnvironmentValues {
    var ghosttyTerminalFontConfiguration: GhosttyFontConfiguration {
        get { self[GhosttyTerminalFontConfigurationKey.self] }
        set { self[GhosttyTerminalFontConfigurationKey.self] = newValue }
    }
}

private struct GhosttyTerminalFontConfigurationKey: EnvironmentKey {
    static let defaultValue = GhosttyFontConfiguration.defaultValue
}

enum TerminalAppearance {
    static func terminalFont(
        size: CGFloat = 13,
        configuration: GhosttyFontConfiguration = .defaultValue,
        bold: Bool = false,
        italic: Bool = false,
        text: String? = nil
    ) -> Font {
        Font(nsTerminalFont(
            size: size,
            configuration: configuration,
            bold: bold,
            italic: italic,
            text: text
        ))
    }

    static func nsTerminalFont(
        size: CGFloat = 13,
        configuration: GhosttyFontConfiguration = .defaultValue,
        bold: Bool = false,
        italic: Bool = false,
        text: String? = nil
    ) -> NSFont {
        let scalar = text?.unicodeScalars.first
        let familyNames = configuration.families(
            for: scalar,
            bold: bold,
            italic: italic
        )
        let styleName = configuration.styleName(bold: bold, italic: italic)

        for family in familyNames {
            registerFontFamilyIfNeeded(family)
            if let font = font(
                named: family,
                size: size,
                styleName: styleName,
                bold: bold,
                italic: italic
            ) {
                return font
            }
        }

        let fallback = NSFont.monospacedSystemFont(
            ofSize: size,
            weight: bold ? .bold : .regular
        )
        var styledFallback = fallback
        if italic {
            styledFallback = NSFontManager.shared.convert(
                styledFallback,
                toHaveTrait: .italicFontMask
            )
        }
        return styledFallback
    }

    /// Resolves one terminal glyph through the same configured families used
    /// by Ghostty before falling back to a locally installed Nerd Font. This
    /// keeps prompt icons as font glyphs instead of replacing them with a
    /// different drawing primitive.
    static func nsTerminalGlyphFont(
        size: CGFloat = 13,
        configuration: GhosttyFontConfiguration = .defaultValue,
        bold: Bool = false,
        italic: Bool = false,
        text: String
    ) -> NSFont {
        guard let scalar = text.unicodeScalars.first else {
            return nsTerminalFont(
                size: size,
                configuration: configuration,
                bold: bold,
                italic: italic
            )
        }

        let familyNames = configuration.families(
            for: scalar,
            bold: bold,
            italic: italic
        )
        let styleName = configuration.styleName(bold: bold, italic: italic)
        if let configured = configuredFont(
            in: familyNames,
            size: size,
            styleName: styleName,
            bold: bold,
            italic: italic,
            supporting: scalar
        ) {
            return configured
        }

        if isNerdFontSymbol(scalar), let nerdFont = nerdFont(
            supporting: scalar,
            size: size,
            bold: bold,
            italic: italic
        ) {
            return nerdFont
        }

        let primary = nsTerminalFont(
            size: size,
            configuration: configuration,
            bold: bold,
            italic: italic
        )
        let coreTextFallback = CTFontCreateForString(
            primary,
            text as CFString,
            CFRange(location: 0, length: text.utf16.count)
        )
        if supports(scalar, in: coreTextFallback),
           let fallback = NSFont(
               descriptor: NSFontDescriptor(name: CTFontCopyPostScriptName(coreTextFallback) as String, size: size),
               size: size
           )
        {
            return fallback
        }

        return primary
    }

    static func resolvedFontName(
        configuration: GhosttyFontConfiguration,
        size: CGFloat = 13
    ) -> String {
        nsTerminalFont(size: size, configuration: configuration).displayName ?? "System Monospaced"
    }

    private static func configuredFont(
        in familyNames: [String],
        size: CGFloat,
        styleName: String?,
        bold: Bool,
        italic: Bool,
        supporting scalar: UnicodeScalar
    ) -> NSFont? {
        for family in familyNames {
            registerFontFamilyIfNeeded(family)
            guard let candidate = font(
                named: family,
                size: size,
                styleName: styleName,
                bold: bold,
                italic: italic
            ), supports(scalar, in: candidate) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func nerdFont(
        supporting scalar: UnicodeScalar,
        size: CGFloat,
        bold: Bool,
        italic: Bool
    ) -> NSFont? {
        let preferredFamilies = [
            "Symbols Nerd Font Mono",
            "Symbols Nerd Font",
            "D2CodingLigature Nerd Font Mono",
            "D2CodingLigature Nerd Font",
            "D2CodingLigature Nerd Font Propo"
        ]
        let installedFamilies = NSFontManager.shared.availableFontFamilies.filter {
            $0.localizedCaseInsensitiveContains("Nerd Font")
        }
        var candidates: [String] = []
        var seen = Set<String>()
        for family in preferredFamilies + installedFamilies where seen.insert(family).inserted {
            candidates.append(family)
        }
        return configuredFont(
            in: candidates,
            size: size,
            styleName: nil,
            bold: bold,
            italic: italic,
            supporting: scalar
        )
    }

    private static func supports(_ scalar: UnicodeScalar, in font: CTFont) -> Bool {
        var characters = Array(String(scalar).utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return characters.withUnsafeMutableBufferPointer { characterBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                guard let characterBaseAddress = characterBuffer.baseAddress,
                      let glyphBaseAddress = glyphBuffer.baseAddress,
                      CTFontGetGlyphsForCharacters(
                          font,
                          characterBaseAddress,
                          glyphBaseAddress,
                          characterBuffer.count
                      )
                else {
                    return false
                }
                return glyphBuffer.contains { $0 != 0 }
            }
        }
    }

    private static func isNerdFontSymbol(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0xE000 ... 0xF8FF, 0xF0000 ... 0xFFFFD, 0x100000 ... 0x10FFFD:
            return true
        default:
            return false
        }
    }

    private static func font(
        named family: String,
        size: CGFloat,
        styleName: String?,
        bold: Bool,
        italic: Bool
    ) -> NSFont? {
        if let styleName,
           styleName.caseInsensitiveCompare("false") != .orderedSame,
           !styleName.isEmpty,
           let styled = namedStyleFont(family: family, styleName: styleName, size: size)
        {
            return styled
        }

        let names = [
            family,
            "\(family) Regular",
            "\(family)-Regular"
        ]
        guard var font = names.lazy.compactMap({ NSFont(name: $0, size: size) }).first else {
            return nil
        }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }

    private static func namedStyleFont(family: String, styleName: String, size: CGFloat) -> NSFont? {
        let names = [
            "\(family) \(styleName)",
            "\(family)-\(styleName)",
            "\(family)\(styleName)"
        ]
        for name in names {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }

        if let members = NSFontManager.shared.availableMembers(ofFontFamily: family) {
            for member in members {
                guard member.count > 1,
                      let postScriptName = member[0] as? String,
                      let advertisedStyle = member[1] as? String,
                      advertisedStyle.localizedCaseInsensitiveContains(styleName)
                else {
                    continue
                }
                if let font = NSFont(name: postScriptName, size: size) {
                    return font
                }
            }
        }
        return nil
    }

    private static let fontRegistrationState = FontRegistrationState()

    private static func registerFontFamilyIfNeeded(_ family: String) {
        let normalizedFamily = normalizedFontIdentifier(family)
        guard !normalizedFamily.isEmpty else { return }
        fontRegistrationState.lock.lock()
        defer { fontRegistrationState.lock.unlock() }
        guard fontRegistrationState.attemptedFamilies.insert(normalizedFamily).inserted else { return }
        guard !NSFontManager.shared.availableFontFamilies.contains(where: {
            normalizedFontIdentifier($0) == normalizedFamily
        }) else { return }

        let fileManager = FileManager.default
        let homeFonts = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
        let directories = [homeFonts, URL(fileURLWithPath: "/Library/Fonts", isDirectory: true)]
        let candidateURLs = directories.flatMap { directory in
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }.filter { url in
            let pathIdentifier = normalizedFontIdentifier(url.deletingPathExtension().lastPathComponent)
            return pathIdentifier.contains(normalizedFamily) || normalizedFamily.contains(pathIdentifier)
        }

        for url in candidateURLs where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            error?.release()
        }
    }

    private static func normalizedFontIdentifier(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(String.init).joined()
    }
}

private final class FontRegistrationState: @unchecked Sendable {
    let lock = NSLock()
    var attemptedFamilies = Set<String>()
}
