import Foundation

public enum SecureFileExporterError: Error, Equatable, LocalizedError, Sendable {
    case sourceDoesNotExist
    case sourceIsNotRegularFile
    case destinationIsNotFileURL
    case destinationDirectoryDoesNotExist
    case destinationDirectoryIsNotDirectory
    case destinationIsDirectory
    case sourceAndDestinationAreSame

    public var errorDescription: String? {
        switch self {
        case .sourceDoesNotExist:
            "The requested file is no longer available for export."
        case .sourceIsNotRegularFile:
            "Only regular files can be exported."
        case .destinationIsNotFileURL:
            "Choose a local file location for the export."
        case .destinationDirectoryDoesNotExist:
            "The selected export folder no longer exists."
        case .destinationDirectoryIsNotDirectory:
            "The selected export parent is not a folder."
        case .destinationIsDirectory:
            "Choose a file name, not a folder."
        case .sourceAndDestinationAreSame:
            "The export destination must differ from the source file."
        }
    }
}

/// Copies a user-requested file without exposing its contents to the caller.
/// The destination is staged beside its final path, replaced only after the
/// copy succeeds, and made private to the current macOS account.
public enum SecureFileExporter {
    public static func exportFile(from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try exportFileSynchronously(from: sourceURL, to: destinationURL)
        }.value
    }

    private static func exportFileSynchronously(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceURL = sourceURL.standardizedFileURL
        let destinationURL = destinationURL.standardizedFileURL
        let fileManager = FileManager.default

        guard sourceURL.isFileURL, destinationURL.isFileURL else {
            throw SecureFileExporterError.destinationIsNotFileURL
        }
        guard sourceURL.path != destinationURL.path else {
            throw SecureFileExporterError.sourceAndDestinationAreSame
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SecureFileExporterError.sourceDoesNotExist
        }
        guard try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SecureFileExporterError.sourceIsNotRegularFile
        }

        let destinationDirectory = destinationURL.deletingLastPathComponent()
        var destinationDirectoryIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: destinationDirectory.path,
            isDirectory: &destinationDirectoryIsDirectory
        ) else {
            throw SecureFileExporterError.destinationDirectoryDoesNotExist
        }
        guard destinationDirectoryIsDirectory.boolValue else {
            throw SecureFileExporterError.destinationDirectoryIsNotDirectory
        }

        var destinationIsDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory),
           destinationIsDirectory.boolValue {
            throw SecureFileExporterError.destinationIsDirectory
        }

        let stagingURL = destinationDirectory.appendingPathComponent(
            ".osxterm-export-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }
}
