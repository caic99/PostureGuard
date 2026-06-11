// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PostureGuard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PostureGuard",
            path: "Sources/PostureGuard"
        )
    ]
)
