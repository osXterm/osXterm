import Foundation

public enum AtomicJSONStoreError: Error, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "Unsupported settings document version: \(version)."
        case let .invalidDirectory(url): "Unable to create settings directory at \(url.path)."
        }
    }
}

public struct AtomicJSONStore<Document: Codable & Sendable>: Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(default defaultDocument: @autoclosure () -> Document) throws -> Document {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return defaultDocument() }
        return try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ document: Document) throws {
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AtomicJSONStoreError.invalidDirectory(directory)
        }

        let data = try encoder.encode(document)
        let stagingURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: stagingURL) }
        try data.write(to: stagingURL, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)

        if manager.fileExists(atPath: fileURL.path) {
            _ = try manager.replaceItemAt(fileURL, withItemAt: stagingURL, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: stagingURL, to: fileURL)
        }
    }
}
