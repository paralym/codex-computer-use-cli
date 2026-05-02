// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "codex-computer-use",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "codex-cu", targets: ["CodexCU"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "CodexCU",
            dependencies: [
                "CodexCUCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "CodexCUCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "CodexCUCoreTests",
            dependencies: ["CodexCUCore"]
        ),
    ]
)
