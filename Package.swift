// swift-tools-version: 5.9
import PackageDescription

// Debug-only: warn when an expression or function body takes too long to
// type-check. These are the slow spots that compile locally but can exceed the
// CI toolchain's type-checker budget ("unable to type-check in reasonable
// time"). Warnings only, and only in debug builds, so `swift build`/`swift test`
// and CI surface them while release/DMG builds stay clean.
let typeCheckWarnings: [SwiftSetting] = [
    .unsafeFlags(
        [
            "-Xfrontend", "-warn-long-expression-type-checking=500",
            "-Xfrontend", "-warn-long-function-bodies=800",
        ],
        .when(configuration: .debug)),
]

let package = Package(
    name: "ChzzkDownloader",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        // Native capture core (long-term goal: fully replace streamlink + ffmpeg).
        // Pure, dependency-free, and independently testable. Used by the app behind
        // the experimental "내장 엔진" flag for live recording and VOD downloads.
        .target(
            name: "ChzzkCaptureCore",
            exclude: ["README.md"],
            swiftSettings: typeCheckWarnings
        ),
        .executableTarget(
            name: "ChzzkDownloader",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "ChzzkCaptureCore",
            ],
            exclude: [
                "cdm.icon",
                "Resources/plugin",
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: typeCheckWarnings
        ),
        .testTarget(
            name: "ChzzkDownloaderTests",
            dependencies: ["ChzzkDownloader"]
        ),
        .testTarget(
            name: "ChzzkCaptureCoreTests",
            dependencies: ["ChzzkCaptureCore"]
        )
    ]
)
