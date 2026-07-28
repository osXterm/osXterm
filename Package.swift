// swift-tools-version: 6.0

import Foundation
import PackageDescription

let ghosttyVtCommit = "4c725242b7dbe8c77c6e227ef1f9540c5ef17921"

#if arch(arm64)
let ghosttyVtArchitecture = "arm64"
#elseif arch(x86_64)
let ghosttyVtArchitecture = "x86_64"
#else
#error("osXterm requires an arm64 or x86_64 Ghostty VT artifact on macOS.")
#endif

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
let ghosttyVtArtifactDirectory = packageDirectory
    .appendingPathComponent("Vendor/GhosttyVt/Artifacts")
    .appendingPathComponent(ghosttyVtCommit)
    .appendingPathComponent("\(ghosttyVtArchitecture)-macos")

let package = Package(
    name: "osXterm",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "OsXTermCore", targets: ["OsXTermCore"]),
        .executable(name: "osXterm", targets: ["osXterm"]),
        .executable(name: "osXtermAskPass", targets: ["osXtermAskPass"]),
        .executable(name: "osXtermChecks", targets: ["osXtermChecks"])
    ],
    targets: [
        .target(
            name: "GhosttyVt",
            path: "Vendor/GhosttyVt",
            sources: ["Sources/GhosttyVtShim.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath(
                    "Artifacts/\(ghosttyVtCommit)/\(ghosttyVtArchitecture)-macos/include"
                )
            ],
            linkerSettings: [
                .unsafeFlags(["-L", ghosttyVtArtifactDirectory.appendingPathComponent("lib").path]),
                .linkedLibrary("ghostty-vt")
            ]
        ),
        .target(name: "OsXTermCore", dependencies: ["GhosttyVt"]),
        .executableTarget(
            name: "osXterm",
            dependencies: ["OsXTermCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "osXtermAskPass",
            dependencies: ["OsXTermCore"]
        ),
        .executableTarget(
            name: "osXtermChecks",
            dependencies: ["OsXTermCore"]
        ),
        .testTarget(
            name: "OsXTermCoreTests",
            dependencies: ["OsXTermCore"]
        )
    ]
)
