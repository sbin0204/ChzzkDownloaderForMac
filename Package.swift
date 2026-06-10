// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChzzkDownloader",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        .executableTarget(
            name: "ChzzkDownloader",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: [
                "cdm.icon",
                "Resources/plugin",
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ChzzkDownloaderTests",
            dependencies: ["ChzzkDownloader"]
        )
    ]
)
