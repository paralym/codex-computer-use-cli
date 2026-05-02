// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "codex-computer-use",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "codex-cu", targets: ["CodexCU"]),
        .executable(name: "codex-cu-mcp", targets: ["CodexCUServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "CodexCU",
            dependencies: [
                "CodexCUCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "CodexCUServer",
            dependencies: [
                "CodexCUCore",
                .product(name: "MCP", package: "swift-sdk"),
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
