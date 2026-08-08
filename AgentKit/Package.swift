// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .executable(name: "iris-cli", targets: ["iris-cli"]),
    ],
    targets: [
        .target(
            name: "AgentKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "iris-cli",
            dependencies: ["AgentKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
