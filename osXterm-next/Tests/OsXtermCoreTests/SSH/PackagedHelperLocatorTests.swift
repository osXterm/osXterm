import Foundation
import Testing
@testable import OsXtermCore

struct PackagedHelperLocatorTests {
    @Test
    func prefersTheHelperInsideThePackagedApp() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let bundledHelper = fixture.bundle.appendingPathComponent("Contents/MacOS/osXtermAskPass")
        let siblingHelper = fixture.executable.deletingLastPathComponent().appendingPathComponent("osXtermAskPass")
        try makeExecutable(at: bundledHelper)
        try makeExecutable(at: siblingHelper)

        let located = try PackagedHelperLocator.locate(
            named: "osXtermAskPass",
            bundleURL: fixture.bundle,
            executableURL: fixture.executable
        )

        #expect(located == bundledHelper)
    }

    @Test
    func usesTheSiblingHelperForADevelopmentBuild() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let siblingHelper = fixture.executable.deletingLastPathComponent().appendingPathComponent("osXtermProxy")
        try makeExecutable(at: siblingHelper)

        let located = try PackagedHelperLocator.locate(
            named: "osXtermProxy",
            bundleURL: fixture.bundle,
            executableURL: fixture.executable
        )

        #expect(located == siblingHelper)
    }

    @Test
    func rejectsAHelperThatIsNotPackagedOrBuiltBesideTheExecutable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: PackagedHelperLocatorError.unavailable("osXtermProxy")) {
            try PackagedHelperLocator.locate(
                named: "osXtermProxy",
                bundleURL: fixture.bundle,
                executableURL: fixture.executable
            )
        }
    }

    private func makeFixture() throws -> (root: URL, bundle: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osxterm-helper-locator-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("osXterm.app", isDirectory: true)
        let executable = root.appendingPathComponent("development/osXterm")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        return (root, bundle, executable)
    }

    private func makeExecutable(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
