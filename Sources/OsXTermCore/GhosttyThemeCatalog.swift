import Foundation

/// The color values understood by Ghostty theme files.
public struct GhosttyThemeColors: Equatable, Sendable {
    public var background: String?
    public var foreground: String?
    public var cursorColor: String?
    public var cursorText: String?
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var palette: [Int: String]

    public init(
        background: String? = nil,
        foreground: String? = nil,
        cursorColor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [Int: String] = [:]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }

    public func merged(overrides: GhosttyThemeColors) -> GhosttyThemeColors {
        GhosttyThemeColors(
            background: overrides.background ?? background,
            foreground: overrides.foreground ?? foreground,
            cursorColor: overrides.cursorColor ?? cursorColor,
            cursorText: overrides.cursorText ?? cursorText,
            selectionBackground: overrides.selectionBackground ?? selectionBackground,
            selectionForeground: overrides.selectionForeground ?? selectionForeground,
            palette: palette.merging(overrides.palette) { _, override in override }
        )
    }

    public static let ghosttyDark = GhosttyThemeColors(
        background: "#07080c",
        foreground: "#e0e6f2",
        cursorColor: "#ffffff",
        cursorText: "#07080c",
        selectionBackground: "#303544",
        selectionForeground: "#e0e6f2"
    )

    public static let solarizedDark = GhosttyThemeColors(
        background: "#002b36",
        foreground: "#839496",
        cursorColor: "#93a1a1",
        cursorText: "#002b36",
        selectionBackground: "#586e75",
        selectionForeground: "#eee8d5"
    )

    public static let solarizedLight = GhosttyThemeColors(
        background: "#fdf6e3",
        foreground: "#657b83",
        cursorColor: "#586e75",
        cursorText: "#fdf6e3",
        selectionBackground: "#eee8d5",
        selectionForeground: "#586e75"
    )

    public static let dracula = GhosttyThemeColors(
        background: "#282a36",
        foreground: "#f8f8f2",
        cursorColor: "#f8f8f2",
        cursorText: "#282a36",
        selectionBackground: "#44475a",
        selectionForeground: "#f8f8f2"
    )
}

public struct GhosttyThemeDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let source: String
    public let fileURL: URL?
    public let colors: GhosttyThemeColors

    public init(
        id: String,
        name: String,
        source: String,
        fileURL: URL? = nil,
        colors: GhosttyThemeColors
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.fileURL = fileURL
        self.colors = colors
    }
}

/// A font family range from Ghostty's `font-codepoint-map` setting.
public struct GhosttyFontCodepointMapping: Equatable, Sendable {
    public let lowerBound: UInt32
    public let upperBound: UInt32
    public let family: String

    public init(lowerBound: UInt32, upperBound: UInt32, family: String) {
        self.lowerBound = min(lowerBound, upperBound)
        self.upperBound = max(lowerBound, upperBound)
        self.family = family
    }

    public func contains(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return lowerBound ... upperBound ~= value
    }
}

/// The font settings used by Ghostty for terminal cells.
///
/// Ghostty treats `font-family` as an ordered fallback list and allows
/// individual Unicode ranges to select another family. Keeping this data in
/// the shared OsXTermCore model lets the AppKit canvas, SwiftUI preview, and
/// SFTP path field use exactly the same configuration.
public struct GhosttyFontConfiguration: Equatable, Sendable {
    public let families: [String]
    public let boldFamilies: [String]
    public let italicFamilies: [String]
    public let boldItalicFamilies: [String]
    public let size: Double?
    public let style: String?
    public let boldStyle: String?
    public let italicStyle: String?
    public let boldItalicStyle: String?
    public let codepointMappings: [GhosttyFontCodepointMapping]

    public init(
        families: [String] = [],
        boldFamilies: [String] = [],
        italicFamilies: [String] = [],
        boldItalicFamilies: [String] = [],
        size: Double? = nil,
        style: String? = nil,
        boldStyle: String? = nil,
        italicStyle: String? = nil,
        boldItalicStyle: String? = nil,
        codepointMappings: [GhosttyFontCodepointMapping] = []
    ) {
        self.families = Self.normalizedFamilies(families)
        self.boldFamilies = Self.normalizedFamilies(boldFamilies)
        self.italicFamilies = Self.normalizedFamilies(italicFamilies)
        self.boldItalicFamilies = Self.normalizedFamilies(boldItalicFamilies)
        self.size = size
        self.style = Self.normalizedValue(style)
        self.boldStyle = Self.normalizedValue(boldStyle)
        self.italicStyle = Self.normalizedValue(italicStyle)
        self.boldItalicStyle = Self.normalizedValue(boldItalicStyle)
        self.codepointMappings = codepointMappings.filter { !$0.family.isEmpty }
    }

    public static let defaultValue = GhosttyFontConfiguration()

    public var primaryFamily: String? { families.first }

    public var displayFamily: String {
        if families.isEmpty {
            return "Ghostty default"
        }
        return families.joined(separator: ", ")
    }

    /// Returns the explicit family for a codepoint, if Ghostty configured one.
    /// Later mappings win, matching Ghostty's last-setting-wins behavior.
    public func mappedFamily(for scalar: UnicodeScalar) -> String? {
        codepointMappings.reversed().first { $0.contains(scalar) }?.family
    }

    public func families(for scalar: UnicodeScalar?, bold: Bool, italic: Bool) -> [String] {
        let mapped = scalar.flatMap(mappedFamily(for:))
        let styleFamilies: [String]
        switch (bold, italic) {
        case (true, true):
            styleFamilies = boldItalicFamilies
        case (true, false):
            styleFamilies = boldFamilies
        case (false, true):
            styleFamilies = italicFamilies
        case (false, false):
            styleFamilies = []
        }

        var result: [String] = []
        if let mapped, !mapped.isEmpty { result.append(mapped) }
        result.append(contentsOf: styleFamilies)
        result.append(contentsOf: families)
        return Self.uniqueFamilies(result)
    }

    public func styleName(bold: Bool, italic: Bool) -> String? {
        switch (bold, italic) {
        case (true, true): boldItalicStyle
        case (true, false): boldStyle
        case (false, true): italicStyle
        case (false, false): style
        }
    }

    private static func normalizedFamilies(_ values: [String]) -> [String] {
        uniqueFamilies(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private static func uniqueFamilies(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct GhosttyThemeCatalogResult: Sendable {
    public let themes: [GhosttyThemeDefinition]
    public let configuredThemeID: String
    public let configuredThemeName: String?
    public let fontConfiguration: GhosttyFontConfiguration

    public init(
        themes: [GhosttyThemeDefinition],
        configuredThemeID: String,
        configuredThemeName: String?,
        fontConfiguration: GhosttyFontConfiguration = .defaultValue
    ) {
        self.themes = themes
        self.configuredThemeID = configuredThemeID
        self.configuredThemeName = configuredThemeName
        self.fontConfiguration = fontConfiguration
    }
}

/// Discovers Ghostty's installed and user themes, then applies the active
/// Ghostty configuration to the special "Ghostty configuration" entry.
public enum GhosttyThemeCatalog {
    public static let configurationThemeID = "ghostty-config"

    public static func load(
        isDarkAppearance: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        themeDirectories: [URL]? = nil,
        configurationPath: String? = nil
    ) -> GhosttyThemeCatalogResult {
        let configURLs = configurationURLs(
            environment: environment,
            homeDirectory: homeDirectory,
            configurationPath: configurationPath
        )
        var configuration = ConfigValues()
        var visitedFiles = Set<String>()
        for url in configURLs {
            configuration.merge(loadConfigFile(url, homeDirectory: homeDirectory, visited: &visitedFiles))
        }

        let resolvedThemeName = resolveThemeName(
            configuration.values["theme"],
            isDarkAppearance: isDarkAppearance
        )
        let themeDirectories = themeDirectories ?? defaultThemeDirectories(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let themeURLs = discoverThemeURLs(in: themeDirectories)
        var definitionsByName: [String: GhosttyThemeDefinition] = [:]

        for (name, url) in themeURLs {
            let values = loadConfigFile(url, homeDirectory: homeDirectory, visited: &visitedFiles)
            let definition = GhosttyThemeDefinition(
                id: namedThemeID(name),
                name: name,
                source: sourceLabel(for: url, homeDirectory: homeDirectory),
                fileURL: url,
                colors: values.colors
            )
            definitionsByName[name] = definition
        }

        addFallbackDefinitions(to: &definitionsByName)

        let configuredThemeValues: GhosttyThemeColors
        if let resolvedThemeName,
           let themeURL = themeURL(
               for: resolvedThemeName,
               knownThemes: themeURLs,
               homeDirectory: homeDirectory
           ) {
            var themeVisited = Set<String>()
            configuredThemeValues = loadConfigFile(
                themeURL,
                homeDirectory: homeDirectory,
                visited: &themeVisited
            ).colors.merged(overrides: configuration.colors)
        } else if let resolvedThemeName,
                  let knownDefinition = definitionsByName[resolvedThemeName] {
            configuredThemeValues = knownDefinition.colors.merged(overrides: configuration.colors)
        } else {
            configuredThemeValues = GhosttyThemeColors.ghosttyDark.merged(
                overrides: configuration.colors
            )
        }

        let configuredDisplayName: String
        if let resolvedThemeName, !resolvedThemeName.isEmpty {
            configuredDisplayName = "Ghostty config: \(resolvedThemeName)"
        } else {
            configuredDisplayName = "Ghostty config"
        }
        let configuredDefinition = GhosttyThemeDefinition(
            id: configurationThemeID,
            name: configuredDisplayName,
            source: configURLs.isEmpty ? "Ghostty defaults" : "Ghostty configuration",
            fileURL: configURLs.first,
            colors: configuredThemeValues
        )

        let sortedDefinitions = definitionsByName.values.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return GhosttyThemeCatalogResult(
            themes: [configuredDefinition] + sortedDefinitions,
            configuredThemeID: configurationThemeID,
            configuredThemeName: resolvedThemeName,
            fontConfiguration: configuration.fontConfiguration
        )
    }

    public static func namedThemeID(_ name: String) -> String {
        "theme:\(name)"
    }

    /// Returns the user-facing default path used by Ghostty when no custom
    /// path is selected in osXterm. Existing files take precedence so the
    /// field starts with the configuration that Ghostty is already using.
    public static func defaultConfigurationPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let defaultURL = defaultConfigurationURLs(
            environment: environment,
            homeDirectory: homeDirectory
        ).first ?? defaultConfigurationFallbackURL(
            environment: environment,
            homeDirectory: homeDirectory
        )
        return userFacingPath(defaultURL, homeDirectory: homeDirectory)
    }

    /// Resolves a path from the Settings field, including `~` and XDG-style
    /// paths. The returned URL is not required to exist so the open command
    /// can still reveal the containing folder for a new configuration file.
    public static func configurationURL(
        for path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return expandedURL(trimmed, homeDirectory: homeDirectory)
    }

    private static func configurationURLs(
        environment: [String: String],
        homeDirectory: URL,
        configurationPath: String?
    ) -> [URL] {
        if let configurationPath,
           let explicitURL = configurationURL(for: configurationPath, homeDirectory: homeDirectory)
        {
            guard FileManager.default.fileExists(atPath: explicitURL.path) else {
                return []
            }
            return [explicitURL]
        }

        return defaultConfigurationURLs(
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    private static func defaultConfigurationURLs(
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        let xdgConfigHome: URL
        if let configured = environment["XDG_CONFIG_HOME"], !configured.isEmpty {
            xdgConfigHome = expandedURL(configured, homeDirectory: homeDirectory)
        } else {
            xdgConfigHome = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }

        let directories = [
            xdgConfigHome.appendingPathComponent("ghostty", isDirectory: true),
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        ]
        var result: [URL] = []
        var seen = Set<String>()
        for directory in directories {
            for filename in ["config.ghostty", "config"] {
                let url = directory.appendingPathComponent(filename, isDirectory: false)
                guard FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted else {
                    continue
                }
                result.append(url)
            }
        }
        return result
    }

    private static func defaultConfigurationFallbackURL(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let xdgConfigHome: URL
        if let configured = environment["XDG_CONFIG_HOME"], !configured.isEmpty {
            xdgConfigHome = expandedURL(configured, homeDirectory: homeDirectory)
        } else {
            xdgConfigHome = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }
        return xdgConfigHome
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }

    private static func userFacingPath(_ url: URL, homeDirectory: URL) -> String {
        let normalizedPath = url.standardizedFileURL.path
        let normalizedHome = homeDirectory.standardizedFileURL.path
        guard normalizedPath != normalizedHome else { return "~" }
        let homePrefix = normalizedHome.hasSuffix("/") ? normalizedHome : normalizedHome + "/"
        guard normalizedPath.hasPrefix(homePrefix) else { return normalizedPath }
        return "~/" + String(normalizedPath.dropFirst(homePrefix.count))
    }

    private static func defaultThemeDirectories(
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        let xdgConfigHome: URL
        if let configured = environment["XDG_CONFIG_HOME"], !configured.isEmpty {
            xdgConfigHome = expandedURL(configured, homeDirectory: homeDirectory)
        } else {
            xdgConfigHome = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }

        var directories = [
            xdgConfigHome
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("themes", isDirectory: true)
        ]

        let resourceRoots = [
            URL(fileURLWithPath: "/Applications/Ghostty.app", isDirectory: true),
            homeDirectory
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("Ghostty.app", isDirectory: true)
        ]
        for root in resourceRoots {
            directories.append(
                root
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("ghostty", isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
            )
            directories.append(
                root
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
            )
        }

        if let ghosttyBinDirectory = environment["GHOSTTY_BIN_DIR"], !ghosttyBinDirectory.isEmpty {
            let binURL = expandedURL(ghosttyBinDirectory, homeDirectory: homeDirectory)
            directories.append(binURL.appendingPathComponent("ghostty/themes", isDirectory: true))
            directories.append(binURL.appendingPathComponent("themes", isDirectory: true))
        }

        return uniqueURLs(directories)
    }

    private static func discoverThemeURLs(in directories: [URL]) -> [(String, URL)] {
        var themes: [(String, URL)] = []
        var seenNames = Set<String>()
        for directory in directories {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory == false,
                      seenNames.insert(url.lastPathComponent).inserted
                else {
                    continue
                }
                themes.append((url.lastPathComponent, url))
            }
        }
        return themes
    }

    private static func addFallbackDefinitions(
        to definitionsByName: inout [String: GhosttyThemeDefinition]
    ) {
        let fallbacks: [(String, GhosttyThemeColors)] = [
            ("Ghostty Dark", .ghosttyDark),
            ("Solarized Dark", .solarizedDark),
            ("Solarized Light", .solarizedLight),
            ("Dracula", .dracula)
        ]
        for (name, colors) in fallbacks where definitionsByName[name] == nil {
            definitionsByName[name] = GhosttyThemeDefinition(
                id: namedThemeID(name),
                name: name,
                source: "osXterm fallback",
                colors: colors
            )
        }
    }

    private static func themeURL(
        for name: String,
        knownThemes: [(String, URL)],
        homeDirectory: URL
    ) -> URL? {
        let expanded = expandedURL(name, homeDirectory: homeDirectory)
        if expanded.path.hasPrefix("/") && FileManager.default.fileExists(atPath: expanded.path) {
            return expanded
        }
        return knownThemes.first(where: { $0.0 == name })?.1
    }

    private static func resolveThemeName(
        _ rawValue: String?,
        isDarkAppearance: Bool
    ) -> String? {
        guard let rawValue else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        var light: String?
        var dark: String?
        for component in value.split(separator: ",", omittingEmptySubsequences: true) {
            let part = String(component).trimmingCharacters(in: .whitespacesAndNewlines)
            if part.lowercased().hasPrefix("light:") {
                light = String(part.dropFirst("light:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if part.lowercased().hasPrefix("dark:") {
                dark = String(part.dropFirst("dark:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if light != nil || dark != nil {
            return (isDarkAppearance ? dark : light) ?? light ?? dark
        }
        return value
    }

    private static func loadConfigFile(
        _ url: URL,
        homeDirectory: URL,
        visited: inout Set<String>
    ) -> ConfigValues {
        let normalizedPath = url.standardizedFileURL.path
        guard visited.insert(normalizedPath).inserted,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ConfigValues()
        }

        var local = ConfigValues()
        for line in text.components(separatedBy: .newlines) {
            guard let entry = parseLine(line) else {
                continue
            }
            if entry.key == "config-file" {
                local.includes.append(entry.value)
            } else {
                local.set(entry.key, value: entry.value)
            }
        }

        var result = local
        for include in local.includes {
            guard let includeURL = includeURL(
                include,
                relativeTo: url.deletingLastPathComponent(),
                homeDirectory: homeDirectory
            ) else {
                continue
            }
            result.merge(loadConfigFile(includeURL, homeDirectory: homeDirectory, visited: &visited))
        }
        return result
    }

    private static func parseLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }

        let key = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return nil
        }
        let rawValue = trimmed[trimmed.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(key), unquote(String(rawValue)))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              value.first == value.last,
              value.first == "\"" || value.first == "'"
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func includeURL(
        _ value: String,
        relativeTo directory: URL,
        homeDirectory: URL
    ) -> URL? {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("?") {
            path.removeFirst()
        }
        guard !path.isEmpty else {
            return nil
        }
        let expanded = expandedURL(path, homeDirectory: homeDirectory)
        if expanded.path.hasPrefix("/") {
            return expanded
        }
        return directory.appendingPathComponent(path, isDirectory: false)
    }

    private static func expandedURL(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private static func sourceLabel(for url: URL, homeDirectory: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        if path.hasPrefix(homePath) {
            return "User theme"
        }
        if path.contains("Ghostty.app/Contents/Resources") {
            return "Ghostty.app"
        }
        return "Ghostty theme file"
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for url in urls {
            let normalized = url.standardizedFileURL.path
            if seen.insert(normalized).inserted {
                result.append(url)
            }
        }
        return result
    }

    private struct ConfigValues {
        var values: [String: String] = [:]
        var repeatableValues: [String: [String]] = [:]
        var palette: [Int: String] = [:]
        var includes: [String] = []

        mutating func set(_ key: String, value: String) {
            if key == "palette",
               let separator = value.firstIndex(of: "=") {
                let indexText = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let colorText = value[value.index(after: separator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = Int(indexText),
                   let color = GhosttyThemeCatalog.normalizeColor(String(colorText)) {
                    palette[index] = color
                }
                return
            }
            if Self.repeatableKeys.contains(key) {
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    repeatableValues[key] = []
                } else {
                    repeatableValues[key, default: []].append(value)
                }
                return
            }
            values[key] = value
        }

        mutating func merge(_ other: ConfigValues) {
            values.merge(other.values) { _, newer in newer }
            for (key, values) in other.repeatableValues {
                repeatableValues[key, default: []].append(contentsOf: values)
            }
            palette.merge(other.palette) { _, newer in newer }
        }

        var fontConfiguration: GhosttyFontConfiguration {
            GhosttyFontConfiguration(
                families: repeatableValues["font-family"] ?? [],
                boldFamilies: repeatableValues["font-family-bold"] ?? [],
                italicFamilies: repeatableValues["font-family-italic"] ?? [],
                boldItalicFamilies: repeatableValues["font-family-bold-italic"] ?? [],
                size: values["font-size"].flatMap(Double.init),
                style: values["font-style"],
                boldStyle: values["font-style-bold"],
                italicStyle: values["font-style-italic"],
                boldItalicStyle: values["font-style-bold-italic"],
                codepointMappings: repeatableValues["font-codepoint-map"]?.flatMap(Self.parseCodepointMappings) ?? []
            )
        }

        var colors: GhosttyThemeColors {
            GhosttyThemeColors(
                background: Self.normalizeColor(values["background"]),
                foreground: Self.normalizeColor(values["foreground"]),
                cursorColor: Self.normalizeColor(values["cursor-color"]),
                cursorText: Self.normalizeColor(values["cursor-text"]),
                selectionBackground: Self.normalizeColor(values["selection-background"]),
                selectionForeground: Self.normalizeColor(values["selection-foreground"]),
                palette: palette
            )
        }

        private static func normalizeColor(_ value: String?) -> String? {
            guard let value else {
                return nil
            }
            return GhosttyThemeCatalog.normalizeColor(value)
        }

        private static let repeatableKeys: Set<String> = [
            "font-family",
            "font-family-bold",
            "font-family-italic",
            "font-family-bold-italic",
            "font-codepoint-map"
        ]

        private static func parseCodepointMappings(_ value: String) -> [GhosttyFontCodepointMapping] {
            guard let separator = value.firstIndex(of: "=") else { return [] }
            let ranges = value[..<separator]
                .split(separator: ",", omittingEmptySubsequences: true)
            let family = value[value.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !family.isEmpty else { return [] }

            return ranges.compactMap { rawRange in
                let pieces = rawRange.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
                guard let lower = parseCodepoint(String(pieces[0])) else { return nil }
                let upper = pieces.count == 2
                    ? parseCodepoint(String(pieces[1])) ?? lower
                    : lower
                return GhosttyFontCodepointMapping(
                    lowerBound: lower,
                    upperBound: upper,
                    family: family
                )
            }
        }

        private static func parseCodepoint(_ rawValue: String) -> UInt32? {
            let value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let digits = value.hasPrefix("U+") ? String(value.dropFirst(2)) : value
            return UInt32(digits, radix: 16)
        }
    }

    private static func normalizeColor(_ value: String) -> String? {
        var digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit })
        else {
            return nil
        }
        return "#" + digits.lowercased()
    }
}
