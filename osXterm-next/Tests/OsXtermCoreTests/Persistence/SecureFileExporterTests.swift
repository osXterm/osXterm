import Foundation
import Testing
@testable import OsXtermCore

struct SecureFileExporterTests {
    @Test func exportsContentWithPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("session.log")
        let destination = directory.appendingPathComponent("exported-session.log")
        let expected = Data("first line\nsecond line\n".utf8)
        try expected.write(to: source)

        try await SecureFileExporter.exportFile(from: source, to: destination)

        #expect(try Data(contentsOf: destination) == expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    @Test func replacesAnExistingDestinationOnlyAfterStagingNewContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("session.log")
        let destination = directory.appendingPathComponent("exported-session.log")
        try Data("new log".utf8).write(to: source)
        try Data("old log".utf8).write(to: destination)

        try await SecureFileExporter.exportFile(from: source, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "new log")
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!directoryContents.contains(where: { $0.hasPrefix(".osxterm-export-") }))
    }

    @Test func rejectsAnUnavailableSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("missing.log")
        let destination = directory.appendingPathComponent("exported-session.log")

        await #expect(throws: SecureFileExporterError.sourceDoesNotExist) {
            try await SecureFileExporter.exportFile(from: source, to: destination)
        }
    }
}
