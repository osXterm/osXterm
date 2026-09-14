import Foundation

public enum PackagedHelperLocatorError: Error, Equatable, Sendable {
    case unavailable(String)
}

/// Locates an app-owned helper without consulting the user's PATH. A packaged
/// app uses Contents/MacOS, while a SwiftPM development build keeps sibling
/// products beside the main executable.
public enum PackagedHelperLocator {
    public static func locate(
        named name: String,
        bundleURL: URL,
        executableURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let candidates = [
            bundleURL.appendingPathComponent("Contents/MacOS/\(name)"),
            executableURL.deletingLastPathComponent().appendingPathComponent(name)
        ]

        guard let helperURL = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw PackagedHelperLocatorError.unavailable(name)
        }
        return helperURL
    }
}
