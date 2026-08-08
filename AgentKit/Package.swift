// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentKit",
    // macOS 26: Liquid Glass (Phase 3) is macOS 26.0+, and the app requires it anyway.
    // `.v26` isn't in this tools version's enum yet; the string form is equivalent.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .executable(name: "iris-cli", targets: ["iris-cli"]),
        .executable(name: "Iris", targets: ["Iris"]),
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
        .executableTarget(
            name: "Iris",
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
