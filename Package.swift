// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DanmuHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DanmuHUD",
            path: "Sources/DanmuHUD"
        )
    ]
)
