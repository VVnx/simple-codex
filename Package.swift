// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SimpleCodex",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "WeChatCodexBridge",
            targets: ["WeChatCodexBridge"]
        ),
        .executable(
            name: "wechat-codex",
            targets: ["WeChatCodexCLI"]
        ),
        .executable(
            name: "WeChatCodexMenuBar",
            targets: ["WeChatCodexMenuBar"]
        ),
    ],
    targets: [
        .target(name: "WeChatCodexBridge"),
        .executableTarget(
            name: "WeChatCodexCLI",
            dependencies: ["WeChatCodexBridge"]
        ),
        .executableTarget(
            name: "WeChatCodexMenuBar",
            dependencies: ["WeChatCodexBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
            ]
        ),
        .testTarget(
            name: "WeChatCodexBridgeTests",
            dependencies: ["WeChatCodexBridge"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
