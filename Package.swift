// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LampBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LampBar", path: "Sources/LampBar")
    ]
)
