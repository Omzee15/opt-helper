// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OptHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OptHelper", path: "Sources/OptHelper")
    ]
)
