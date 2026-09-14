// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "osXterm",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "OsXtermCore", targets: ["OsXtermCore"]),
        .executable(name: "osXterm", targets: ["osXterm"]),
        .executable(name: "osXtermAskPass", targets: ["osXtermAskPass"]),
        .executable(name: "osXtermProxy", targets: ["osXtermProxy"]),
        .executable(name: "osXtermIntegrationRunner", targets: ["osXtermIntegrationRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")
    ],
    targets: [
        .target(name: "OsXtermCore"),
        .executableTarget(
            name: "osXterm",
            dependencies: [
                "OsXtermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/OsXtermApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(name: "osXtermAskPass", dependencies: ["OsXtermCore"]),
        .executableTarget(name: "osXtermProxy", dependencies: ["OsXtermCore"]),
        .executableTarget(
            name: "osXtermIntegrationRunner",
            dependencies: ["OsXtermCore"],
            path: "Integration/Runner"
        ),
        .testTarget(name: "OsXtermCoreTests", dependencies: ["OsXtermCore"])
    ]
)
