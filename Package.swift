// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "LGController",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "LGController",
            path: "Sources/LGController"
        ),
    ]
)
