// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShakaPachi",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ShakaPachi",
            path: "Sources/ShakaPachi"
        ),
        .testTarget(
            name: "ShakaPachiTests",
            dependencies: ["ShakaPachi"],
            path: "Tests/ShakaPachiTests"
        )
    ]
)
