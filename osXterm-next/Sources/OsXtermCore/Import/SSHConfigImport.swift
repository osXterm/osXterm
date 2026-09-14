import Foundation

public enum SSHConfigDiagnosticSeverity: String, Equatable, Sendable {
    case information
    case warning
    case error
}

public struct SSHConfigSourceLocation: Equatable, Sendable {
    public let source: URL?
    public let line: Int

    public init(source: URL?, line: Int) {
        self.source = source
        self.line = line
    }
}

public struct SSHConfigDiagnostic: Equatable, Sendable {
    public let severity: SSHConfigDiagnosticSeverity
    public let message: String
    public let location: SSHConfigSourceLocation

    public init(
        severity: SSHConfigDiagnosticSeverity,
        message: String,
        location: SSHConfigSourceLocation
    ) {
        self.severity = severity
        self.message = message
        self.location = location
    }
}

public enum SSHConfigImportError: Error, Equatable, Sendable, LocalizedError {
    case unreadableSource(URL, String)
    case includeCycle(URL)
    case includeDepthExceeded(Int)
    case malformedDirective(SSHConfigSourceLocation, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableSource(url, message):
            "Could not read SSH config \(url.path): \(message)"
        case let .includeCycle(url):
            "SSH config Include contains a cycle at \(url.path)."
        case let .includeDepthExceeded(limit):
            "SSH config Include exceeded maximum depth \(limit)."
        case let .malformedDirective(location, message):
            "Malformed SSH config directive at line \(location.line): \(message)"
        }
    }
}

/// Source access is injectable for preview and test flows. Implementations
/// must only read text and expand patterns; they never execute configuration.
public protocol SSHConfigSourceLoading: Sendable {
    func contents(of source: URL) throws -> String
    func resolveIncludes(pattern: String, relativeTo source: URL) throws -> [URL]
}

public struct FileSSHConfigSourceLoader: SSHConfigSourceLoading {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func contents(of source: URL) throws -> String {
        do {
            return try String(contentsOf: source, encoding: .utf8)
        } catch {
            throw SSHConfigImportError.unreadableSource(source, error.localizedDescription)
        }
    }

    public func resolveIncludes(pattern: String, relativeTo source: URL) throws -> [URL] {
        let expanded = try expandHome(pattern, relativeTo: source)
        guard !expanded.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return []
        }

        let hasGlob = expanded.contains("*") || expanded.contains("?")
        if !hasGlob {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? [url] : []
        }

        let patternURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let root = globRoot(for: patternURL.path)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var matches: [URL] = []
        while let candidate = enumerator?.nextObject() as? URL {
            guard matches.count < 256 else { break }
            let resourceValues = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }
            if SSHConfigHostPattern.matches(candidate.standardizedFileURL.path, pattern: patternURL.path) {
                matches.append(candidate.standardizedFileURL)
            }
        }
        return matches.sorted { $0.path < $1.path }
    }

    private func expandHome(_ pattern: String, relativeTo source: URL) throws -> String {
        if pattern == "~" {
            return homeDirectory.path
        }
        if pattern.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(pattern.dropFirst(2))).path
        }
        if pattern.hasPrefix("/") {
            return pattern
        }
        return source.deletingLastPathComponent().appendingPathComponent(pattern).path
    }

    private func globRoot(for path: String) -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var stableComponents: [Substring] = []
        for component in components {
            if component.contains("*") || component.contains("?") {
                break
            }
            stableComponents.append(component)
        }
        let prefix = "/" + stableComponents.joined(separator: "/")
        return URL(fileURLWithPath: prefix.isEmpty ? "/" : prefix, isDirectory: true)
    }
}

public struct SSHConfigDirective: Equatable, Sendable {
    public let keyword: String
    public let value: String
    public let location: SSHConfigSourceLocation

    public init(keyword: String, value: String, location: SSHConfigSourceLocation) {
        self.keyword = keyword
        self.value = value
        self.location = location
    }
}

public struct SSHConfigHostBlock: Equatable, Sendable {
    public let patterns: [String]
    public let directives: [SSHConfigDirective]
    public let location: SSHConfigSourceLocation

    public init(
        patterns: [String],
        directives: [SSHConfigDirective],
        location: SSHConfigSourceLocation
    ) {
        self.patterns = patterns
        self.directives = directives
        self.location = location
    }
}

public struct SSHConfigDocument: Equatable, Sendable {
    public let globalDirectives: [SSHConfigDirective]
    public let hostBlocks: [SSHConfigHostBlock]

    public init(globalDirectives: [SSHConfigDirective], hostBlocks: [SSHConfigHostBlock]) {
        self.globalDirectives = globalDirectives
        self.hostBlocks = hostBlocks
    }
}

public struct SSHConfigImportedProfile: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let alias: String
    public let host: String
    public let port: Int
    public let username: String
    public let identityFiles: [String]
    public let certificateFile: String?
    public let identityAgent: String?
    public let proxyJump: [String]
    public let options: SSHOptions
    public let knownHostsFiles: [String]
    public let unsupportedDirectives: [SSHConfigDirective]

    public init(
        id: UUID = UUID(),
        alias: String,
        host: String,
        port: Int,
        username: String,
        identityFiles: [String],
        certificateFile: String?,
        identityAgent: String?,
        proxyJump: [String],
        options: SSHOptions,
        knownHostsFiles: [String],
        unsupportedDirectives: [SSHConfigDirective]
    ) {
        self.id = id
        self.alias = alias
        self.host = host
        self.port = port
        self.username = username
        self.identityFiles = identityFiles
        self.certificateFile = certificateFile
        self.identityAgent = identityAgent
        self.proxyJump = proxyJump
        self.options = options
        self.knownHostsFiles = knownHostsFiles
        self.unsupportedDirectives = unsupportedDirectives
    }

    public func connectionProfile(
        jumpProfileIDs: [UUID] = [],
        date: Date = .now
    ) -> ConnectionProfile {
        let authentication: AuthenticationMethod
        if let identityFile = identityFiles.first {
            authentication = .privateKey(path: identityFile, passphrase: nil)
        } else {
            authentication = .agent(socketPath: identityAgent)
        }

        return ConnectionProfile(
            id: id,
            name: alias,
            host: host,
            port: port,
            username: username,
            authentication: authentication,
            certificatePath: certificateFile,
            jumpProfileIDs: jumpProfileIDs,
            options: options,
            createdAt: date,
            updatedAt: date
        )
    }
}

public struct SSHConfigImportResult: Equatable, Sendable {
    public let document: SSHConfigDocument
    public let profiles: [SSHConfigImportedProfile]
    public let diagnostics: [SSHConfigDiagnostic]

    public init(
        document: SSHConfigDocument,
        profiles: [SSHConfigImportedProfile],
        diagnostics: [SSHConfigDiagnostic]
    ) {
        self.document = document
        self.profiles = profiles
        self.diagnostics = diagnostics
    }

    /// Converts the preview into persisted profiles without creating secrets.
    /// ProxyJump aliases are linked only when an imported profile has the same
    /// alias or effective host. Direct endpoints stay unlinked for user review.
    public func connectionProfiles(date: Date = .now) -> [ConnectionProfile] {
        let aliasIDs = Dictionary(uniqueKeysWithValues: profiles.map { ($0.alias, $0.id) })
        let hostIDs = Dictionary(
            profiles.map { ($0.host, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        return profiles.map { imported in
            let jumpIDs = imported.proxyJump.compactMap { jump in
                let reference = SSHConfigImportResult.jumpLookupKey(jump)
                return aliasIDs[reference] ?? hostIDs[reference]
            }
            return imported.connectionProfile(jumpProfileIDs: jumpIDs, date: date)
        }
    }

    private static func jumpLookupKey(_ value: String) -> String {
        var result = value
        if let at = result.lastIndex(of: "@") {
            result = String(result[result.index(after: at)...])
        }
        if result.hasPrefix("[") {
            if let closing = result.firstIndex(of: "]") {
                return String(result[result.index(after: result.startIndex)..<closing])
            }
            return result
        }
        if let colon = result.lastIndex(of: ":") {
            return String(result[..<colon])
        }
        return result
    }
}

public struct SSHConfigImporter: Sendable {
    public static let defaultMaximumIncludeDepth = 16

    private let sourceLoader: any SSHConfigSourceLoading
    private let maximumIncludeDepth: Int

    public init(
        sourceLoader: any SSHConfigSourceLoading = FileSSHConfigSourceLoader(),
        maximumIncludeDepth: Int = SSHConfigImporter.defaultMaximumIncludeDepth
    ) {
        self.sourceLoader = sourceLoader
        self.maximumIncludeDepth = maximumIncludeDepth
    }

    public func `import`(from source: URL) throws -> SSHConfigImportResult {
        var state = ParserState()
        try parse(source: source.standardizedFileURL, state: &state, includeStack: [])
        let document = state.document
        let profiles = buildProfiles(from: document, diagnostics: &state.diagnostics)
        return SSHConfigImportResult(
            document: document,
            profiles: profiles,
            diagnostics: state.diagnostics
        )
    }

    /// Parses supplied text without reading or executing external configuration.
    public func `import`(text: String, source: URL? = nil) throws -> SSHConfigImportResult {
        var state = ParserState()
        try parse(text: text, source: source, state: &state, includeStack: [])
        let document = state.document
        let profiles = buildProfiles(from: document, diagnostics: &state.diagnostics)
        return SSHConfigImportResult(
            document: document,
            profiles: profiles,
            diagnostics: state.diagnostics
        )
    }

    private func parse(
        source: URL,
        state: inout ParserState,
        includeStack: [URL]
    ) throws {
        guard includeStack.count < maximumIncludeDepth else {
            throw SSHConfigImportError.includeDepthExceeded(maximumIncludeDepth)
        }
        guard !includeStack.contains(source) else {
            throw SSHConfigImportError.includeCycle(source)
        }
        try parse(
            text: sourceLoader.contents(of: source),
            source: source,
            state: &state,
            includeStack: includeStack + [source]
        )
    }

    private func parse(
        text: String,
        source: URL?,
        state: inout ParserState,
        includeStack: [URL]
    ) throws {
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let location = SSHConfigSourceLocation(source: source, line: offset + 1)
            let line = String(rawLine)
            guard let parsed = try parseLine(line, location: location) else { continue }
            let keyword = parsed.keyword.lowercased()

            switch keyword {
            case "host":
                guard !parsed.values.isEmpty else {
                    throw SSHConfigImportError.malformedDirective(location, "Host requires at least one pattern")
                }
                state.beginHost(patterns: parsed.values, location: location)

            case "match":
                state.beginMatch(location: location, value: parsed.value)

            case "include":
                guard !state.isIgnoringMatch else {
                    state.addDiagnostic(
                        severity: .warning,
                        message: "Include inside a Match block was ignored because the Match condition was not evaluated.",
                        location: location
                    )
                    continue
                }
                guard let source else {
                    state.addDiagnostic(
                        severity: .warning,
                        message: "Include is ignored because this preview has no source file.",
                        location: location
                    )
                    continue
                }
                for pattern in parsed.values {
                    let includes = try sourceLoader.resolveIncludes(pattern: pattern, relativeTo: source)
                    if includes.isEmpty {
                        state.addDiagnostic(
                            severity: .warning,
                            message: "Include matched no files: \(pattern)",
                            location: location
                        )
                    }
                    for include in includes {
                        try parse(
                            source: include.standardizedFileURL,
                            state: &state,
                            includeStack: includeStack
                        )
                    }
                }

            default:
                let directive = SSHConfigDirective(keyword: keyword, value: parsed.value, location: location)
                state.add(directive)
            }
        }
    }

    private func buildProfiles(
        from document: SSHConfigDocument,
        diagnostics: inout [SSHConfigDiagnostic]
    ) -> [SSHConfigImportedProfile] {
        let aliases = document.hostBlocks.flatMap(\.patterns)
            .filter { pattern in
                !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
            }
        var seenAliases = Set<String>()
        let uniqueAliases = aliases.filter { seenAliases.insert($0).inserted }

        var profiles: [SSHConfigImportedProfile] = []
        profiles.reserveCapacity(uniqueAliases.count)
        for alias in uniqueAliases {
            let directives = effectiveDirectives(for: alias, document: document)
            profiles.append(buildProfile(alias: alias, directives: directives, diagnostics: &diagnostics))
        }
        return profiles
    }

    private func effectiveDirectives(
        for alias: String,
        document: SSHConfigDocument
    ) -> [SSHConfigDirective] {
        var result = document.globalDirectives
        for block in document.hostBlocks where blockMatches(block.patterns, alias: alias) {
            result.append(contentsOf: block.directives)
        }
        return result
    }

    private func buildProfile(
        alias: String,
        directives: [SSHConfigDirective],
        diagnostics: inout [SSHConfigDiagnostic]
    ) -> SSHConfigImportedProfile {
        var scalarValues: [String: SSHConfigDirective] = [:]
        var identityFiles: [String] = []
        var knownHostsFiles: [String] = []
        var proxyJump: [String] = []
        var unsupported: [SSHConfigDirective] = []

        for directive in directives {
            switch directive.keyword {
            case "identityfile":
                identityFiles.append(directive.value)
            case "userknownhostsfile":
                knownHostsFiles.append(contentsOf: directive.value.split(whereSeparator: \.isWhitespace).map(String.init))
            case "proxyjump":
                if proxyJump.isEmpty, directive.value.lowercased() != "none" {
                    proxyJump = directive.value.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                }
            case "proxycommand":
                unsupported.append(directive)
                diagnostics.append(
                    SSHConfigDiagnostic(
                        severity: .warning,
                        message: "ProxyCommand was preserved as unsupported text and was not executed.",
                        location: directive.location
                    )
                )
            default:
                if scalarValues[directive.keyword] == nil {
                    scalarValues[directive.keyword] = directive
                }
            }
        }

        let port = parsePort(scalarValues["port"], defaultValue: 22, diagnostics: &diagnostics)
        let connectTimeout = parseInterval(
            scalarValues["connecttimeout"],
            defaultValue: SSHOptions.default.connectTimeout,
            diagnostics: &diagnostics
        )
        let serverAliveInterval = parseInterval(
            scalarValues["serveraliveinterval"],
            defaultValue: SSHOptions.default.serverAliveInterval,
            diagnostics: &diagnostics
        )
        let serverAliveCountMax = parseInteger(
            scalarValues["serveralivecountmax"],
            defaultValue: SSHOptions.default.serverAliveCountMax,
            range: 0 ... 100,
            diagnostics: &diagnostics
        )
        let forwardAgent = parseBoolean(
            scalarValues["forwardagent"],
            defaultValue: false,
            diagnostics: &diagnostics
        )

        let options = SSHOptions(
            connectTimeout: connectTimeout,
            serverAliveInterval: serverAliveInterval,
            serverAliveCountMax: serverAliveCountMax,
            autoReconnect: false,
            maximumReconnectAttempts: SSHOptions.default.maximumReconnectAttempts,
            forwardAgent: forwardAgent,
            requestTTY: parseRequestTTY(scalarValues["requesttty"], diagnostics: &diagnostics)
        )

        let supported = Set([
            "hostname", "user", "port", "identityfile", "certificatefile", "identityagent",
            "proxyjump", "proxycommand", "forwardagent", "connecttimeout", "serveraliveinterval",
            "serveralivecountmax", "requesttty", "userknownhostsfile", "stricthostkeychecking",
            "identitiesonly", "tcpkeepalive"
        ])
        for directive in directives where !supported.contains(directive.keyword) {
            unsupported.append(directive)
        }

        return SSHConfigImportedProfile(
            alias: alias,
            host: scalarValues["hostname"]?.value ?? alias,
            port: port,
            username: scalarValues["user"]?.value ?? "",
            identityFiles: identityFiles,
            certificateFile: scalarValues["certificatefile"]?.value,
            identityAgent: scalarValues["identityagent"]?.value,
            proxyJump: proxyJump,
            options: options,
            knownHostsFiles: knownHostsFiles,
            unsupportedDirectives: unsupported
        )
    }

    private func parsePort(
        _ directive: SSHConfigDirective?,
        defaultValue: Int,
        diagnostics: inout [SSHConfigDiagnostic]
    ) -> Int {
        guard let directive else { return defaultValue }
        guard let value = Int(directive.value), (1 ... 65_535).contains(value) else {
            diagnostics.append(
                SSHConfigDiagnostic(
                    severity: .warning,
                    message: "Port is invalid and defaulted to \(defaultValue).",
                    location: directive.location
                )
            )
            return defaultValue
        }
        return value
    }

    private func parseInterval(
        _ directive: SSHConfigDirective?,
        defaultValue: TimeInterval,
        diagnostics: inout [SSHConfigDiagnostic]
    ) -> TimeInterval {
        guard let directive else { return defaultValue }
        guard let value = TimeInterval(directive.value), value >= 0, value <= 86_400 else {
            diagnostics.append(
                SSHConfigDiagnostic(
                    severity: .warning,
                    message: "\(directive.keyword) is invalid and defaulted.",
                    location: directive.location
                )
            )
            return defaultValue
        }
        return value
    }

    private func parseInteger(
        _ directive: SSHConfigDirective?,
        defaultValue: Int,
        range: ClosedRange<Int>,
        diagnostics: inout [SSHConfigDiagnostic]
    ) -> Int {
        guard let directive else { return defaultValue }
        guard let value = Int(directive.value), range.contains(value) else {
            diagnostics.append(
                SSHConfigDiagnostic(
                    severity: .warning,
                    message: "\(directive.keyword) is invalid and defaulted.",
                    location: directive.location
                )
            )
            return defaultValue
        }
        return value
    }

    private func parseBoolean(
        _ directive: SSHConfigDirective?,
        defaultValue: Bool,
        diagnostics: inout [SSHConfigDiagnostic]
    ) -> Bool {
        guard let directive else { return defaultValue }
        switch directive.value.lowercased() {
        case "yes", "true", "on": return true
        case "no", "false", "off": return false
        default:
            diagnostics.append(
                SSHConfigDiagnostic(
                    severity: .warning,
                    message: "\(directive.keyword) is invalid and defaulted.",
                    location: directive.location
                )
            )
            return defaultValue
        }
    }

    private func parseRequestTTY(
        _ directive: SSHConfigDirective?,
        diagnostics: inout [SSHConfigDiagnostic]
    ) -> Bool {
        guard let directive else { return SSHOptions.default.requestTTY }
        switch directive.value.lowercased() {
        case "yes", "true", "on", "force": return true
        case "no", "false", "off": return false
        default:
            diagnostics.append(
                SSHConfigDiagnostic(
                    severity: .warning,
                    message: "RequestTTY is invalid and defaulted.",
                    location: directive.location
                )
            )
            return SSHOptions.default.requestTTY
        }
    }

    private func blockMatches(_ patterns: [String], alias: String) -> Bool {
        var hasPositiveMatch = false
        for rawPattern in patterns {
            let isNegated = rawPattern.hasPrefix("!")
            let pattern = isNegated ? String(rawPattern.dropFirst()) : rawPattern
            guard SSHConfigHostPattern.matches(alias, pattern: pattern) else { continue }
            if isNegated { return false }
            hasPositiveMatch = true
        }
        return hasPositiveMatch
    }

    private func parseLine(
        _ line: String,
        location: SSHConfigSourceLocation
    ) throws -> ParsedLine? {
        let tokens = try SSHConfigLexer.tokens(in: line, location: location)
        guard let first = tokens.first else { return nil }

        let keyword: String
        var values: [String]
        if let equal = first.firstIndex(of: "=") {
            keyword = String(first[..<equal])
            let initialValue = String(first[first.index(after: equal)...])
            values = initialValue.isEmpty
                ? Array(tokens.dropFirst())
                : [initialValue] + Array(tokens.dropFirst())
        } else {
            keyword = first
            values = Array(tokens.dropFirst())
        }
        guard !keyword.isEmpty else {
            throw SSHConfigImportError.malformedDirective(location, "Directive name is empty")
        }
        return ParsedLine(keyword: keyword, values: values)
    }

    private struct ParsedLine {
        let keyword: String
        let values: [String]
        var value: String { values.joined(separator: " ") }
    }

    private struct ParserState {
        private enum Scope {
            case global
            case host(Int)
            case ignoredMatch
        }

        private var globalDirectives: [SSHConfigDirective] = []
        private var mutableHostBlocks: [MutableHostBlock] = []
        private var scope: Scope = .global
        var diagnostics: [SSHConfigDiagnostic] = []

        var isIgnoringMatch: Bool {
            if case .ignoredMatch = scope {
                return true
            }
            return false
        }

        var document: SSHConfigDocument {
            SSHConfigDocument(
                globalDirectives: globalDirectives,
                hostBlocks: mutableHostBlocks.map {
                    SSHConfigHostBlock(
                        patterns: $0.patterns,
                        directives: $0.directives,
                        location: $0.location
                    )
                }
            )
        }

        mutating func beginHost(patterns: [String], location: SSHConfigSourceLocation) {
            mutableHostBlocks.append(MutableHostBlock(patterns: patterns, location: location))
            scope = .host(mutableHostBlocks.count - 1)
        }

        mutating func beginMatch(location: SSHConfigSourceLocation, value: String) {
            let isExec = value.split(whereSeparator: \.isWhitespace).first?.lowercased() == "exec"
            addDiagnostic(
                severity: .warning,
                message: isExec
                    ? "Match exec is rejected and was not executed. Its conditional directives were ignored."
                    : "Match conditions are not evaluated during import. Their conditional directives were ignored.",
                location: location
            )
            scope = .ignoredMatch
        }

        mutating func add(_ directive: SSHConfigDirective) {
            switch scope {
            case .global:
                globalDirectives.append(directive)
            case let .host(index):
                mutableHostBlocks[index].directives.append(directive)
            case .ignoredMatch:
                break
            }
        }

        mutating func addDiagnostic(
            severity: SSHConfigDiagnosticSeverity,
            message: String,
            location: SSHConfigSourceLocation
        ) {
            diagnostics.append(
                SSHConfigDiagnostic(severity: severity, message: message, location: location)
            )
        }

        private struct MutableHostBlock {
            let patterns: [String]
            var directives: [SSHConfigDirective] = []
            let location: SSHConfigSourceLocation
        }
    }
}

private enum SSHConfigLexer {
    static func tokens(
        in line: String,
        location: SSHConfigSourceLocation
    ) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in line {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "#" {
                break
            }
            if character.isWhitespace {
                finishToken(&tokens, current: &current)
            } else {
                current.append(character)
            }
        }

        if isEscaping {
            current.append("\\")
        }
        guard quote == nil else {
            throw SSHConfigImportError.malformedDirective(location, "Unterminated quoted string")
        }
        finishToken(&tokens, current: &current)
        return tokens
    }

    private static func finishToken(_ tokens: inout [String], current: inout String) {
        guard !current.isEmpty else { return }
        tokens.append(current)
        current = ""
    }
}

private enum SSHConfigHostPattern {
    static func matches(_ candidate: String, pattern: String) -> Bool {
        let text = Array(candidate.lowercased().utf8)
        let wildcard = Array(pattern.lowercased().utf8)
        guard !wildcard.isEmpty else { return text.isEmpty }
        var previous = Array(repeating: false, count: wildcard.count + 1)
        previous[0] = true
        for index in 1 ... wildcard.count where wildcard[index - 1] == 42 {
            previous[index] = previous[index - 1]
        }

        for byte in text {
            var current = Array(repeating: false, count: wildcard.count + 1)
            for index in 1 ... wildcard.count {
                switch wildcard[index - 1] {
                case 42: // *
                    current[index] = current[index - 1] || previous[index]
                case 63: // ?
                    current[index] = previous[index - 1]
                default:
                    current[index] = previous[index - 1] && wildcard[index - 1] == byte
                }
            }
            previous = current
        }
        return previous[wildcard.count]
    }
}
