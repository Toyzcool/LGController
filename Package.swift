// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LGController",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LGController",
            path: "Sources/LGController"
        ),
    ]
)
