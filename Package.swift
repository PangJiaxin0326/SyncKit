// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "SyncKit",
    platforms: [
        .iOS("26.5"),
        .macOS("26.5"),
        .visionOS("26.5"),
    ],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/PangJiaxin0326/AIToolKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "AIToolKit", package: "AIToolKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"],
            swiftSettings: swiftSettings
        ),
    ]
)
