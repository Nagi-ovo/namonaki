// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Namonaki",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Namonaki",
            path: "Sources/Namonaki"
        ),
        .testTarget(
            name: "NamonakiTests",
            dependencies: ["Namonaki"],
            path: "Tests/NamonakiTests"
        )
    ]
)
