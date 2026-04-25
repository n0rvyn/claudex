// swift-tools-version: 6.2

import PackageDescription

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
            sources: ["lib/common", "lib/compress"],
            publicHeadersPath: "include",
            cSettings: [
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_MULTITHREAD", to: "1"),
            ]
        ),
        .target(
            name: "CCRouterCore",
            dependencies: ["CZstd"],
            resources: [
                .process("Resources"),
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
