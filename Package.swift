// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSportsBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacSportsBar",
            path: "Sources/MacSportsBar"
        ),
        .testTarget(
            name: "MacSportsBarTests",
            dependencies: ["MacSportsBar"],
            path: "Tests/MacSportsBarTests",
            resources: [
                // The captured real ESPN payload; copied verbatim so the decode test can
                // load it via `Bundle.module`.
                .copy("Fixtures")
            ]
        )
    ]
)
