// swift-tools-version: 6.2

import PackageDescription

let vendoredZstdArchive = "Vendor/zstd/lib/libzstd.a"

let package = Package(
    name: "Claudex",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "CCRouterCore",
            targets: ["CCRouterCore"]
        ),
        .executable(
            name: "claudex-daemon",
            targets: ["CCRouterDaemon"]
        ),
        .executable(
            name: "claudex-app",
            targets: ["CCRouterApp"]
        ),
    ],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CCRouterCore",
            dependencies: ["CZstd"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([vendoredZstdArchive]),
            ]
        ),
        .executableTarget(
            name: "CCRouterDaemon",
            dependencies: ["CCRouterCore"]
        ),
        .executableTarget(
            name: "CCRouterApp",
            dependencies: ["CCRouterCore"]
        ),
        .testTarget(
            name: "CCRouterCoreTests",
            dependencies: ["CCRouterCore"],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
