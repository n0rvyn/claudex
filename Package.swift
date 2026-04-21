// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ModelBridge",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "CCRouterCore",
            targets: ["CCRouterCore"]
        ),
        .executable(
            name: "modelbridge-daemon",
            targets: ["CCRouterDaemon"]
        ),
        .executable(
            name: "modelbridge-app",
            targets: ["CCRouterApp"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CZstd",
            pkgConfig: "libzstd",
            providers: [
                .brew(["zstd"]),
            ]
        ),
        .target(
            name: "CCRouterCore",
            dependencies: ["CZstd"]
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
            dependencies: ["CCRouterCore"]
        ),
    ]
)
