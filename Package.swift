// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Bonsai",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Bonsai",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Bonsai",
            resources: [.copy("Resources/Icons")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
