// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexUsageOverlay",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageOverlay",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
