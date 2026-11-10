// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Droppy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Droppy",
            path: "Sources/Droppy"
        )
    ]
)
