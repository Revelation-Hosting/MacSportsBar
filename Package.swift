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
        )
    ]
)
