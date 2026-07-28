import Foundation
import UniformTypeIdentifiers

/// Shared conversion and export support for the SFTP file browser's drag and
/// drop interactions.
///
/// Finder supplies dropped files as either a file URL, its data
/// representation, or a URL string. Remote rows use a file representation so
/// another macOS app can receive the downloaded temporary file.
public enum SFTPDragAndDropSupport {
    /// Turns an item supplied by `NSItemProvider.loadItem` into a local file URL.
    public static func fileURL(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL where url.isFileURL:
            return url
        case let data as Data:
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                return nil
            }
            return url
        case let string as String:
            guard let url = URL(string: string), url.isFileURL else {
                return nil
            }
            return url
        default:
            return nil
        }
    }

    /// Creates a provider whose file representation is produced only when a
    /// destination requests it. The exporter must return a readable local file
    /// URL and runs on the main actor, which lets UI code safely call its
    /// session model while preparing a remote download.
    @MainActor
    public static func remoteFileProvider(
        suggestedFilename: String,
        contentType: UTType = .data,
        export: @escaping @MainActor () async throws -> URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = safeFilename(from: suggestedFilename)

        let exportRequest = FileRepresentationExportRequest(export: export)
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            exportRequest.load(completion: completion)
        }
        return provider
    }

    private static func safeFilename(from suggestedFilename: String) -> String {
        let filename = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        return filename.isEmpty || filename == "." || filename == ".."
            ? "remote-download"
            : filename
    }
}

private final class FileRepresentationExportRequest: @unchecked Sendable {
    private let export: @MainActor () async throws -> URL

    init(export: @escaping @MainActor () async throws -> URL) {
        self.export = export
    }

    func load(
        completion: @escaping @Sendable (URL?, Bool, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let export = export

        let task = Task { @MainActor in
            do {
                guard !Task.isCancelled else {
                    completion(nil, false, Self.cancelledError())
                    return
                }

                let fileURL = try await export()
                guard fileURL.isFileURL else {
                    completion(nil, false, Self.invalidFileError())
                    return
                }
                guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                    completion(nil, false, Self.missingFileError(fileURL))
                    return
                }
                guard !Task.isCancelled else {
                    completion(nil, false, Self.cancelledError())
                    return
                }

                progress.completedUnitCount = 1
                completion(fileURL, false, nil)
            } catch {
                completion(nil, false, error)
            }
        }
        progress.cancellationHandler = {
            task.cancel()
        }
        return progress
    }

    private static func cancelledError() -> NSError {
        NSError(
            domain: "osXterm.SFTPDragAndDrop",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The remote file export was cancelled."]
        )
    }

    private static func invalidFileError() -> NSError {
        NSError(
            domain: "osXterm.SFTPDragAndDrop",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The remote file export did not return a file URL."]
        )
    }

    private static func missingFileError(_ fileURL: URL) -> NSError {
        NSError(
            domain: "osXterm.SFTPDragAndDrop",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "The remote file export did not create \(fileURL.lastPathComponent)."
            ]
        )
    }
}
