// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hypermnesia",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HypermnesiaKit", targets: ["HypermnesiaKit"]),
        .executable(name: "hypermnesia", targets: ["hypermnesia"]),
        .executable(name: "HypermnesiaApp", targets: ["HypermnesiaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        // The platform-agnostic memory engine: models, store, capture, decay, dedup, hydration.
        .target(
            name: "HypermnesiaKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // The headless CLI the Claude Code hooks invoke (capture / hydrate / daemon / doctor).
        .executableTarget(
            name: "hypermnesia",
            dependencies: [
                "HypermnesiaKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The macOS menu-bar + window app (SwiftUI).
        .executableTarget(
            name: "HypermnesiaApp",
            dependencies: [
                "HypermnesiaKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // Sparkle.framework lives next to the binary in a bare `swift build`, and in
                // Contents/Frameworks inside the assembled .app bundle.
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "HypermnesiaKitTests",
            dependencies: ["HypermnesiaKit"]
        ),
        .testTarget(
            name: "HypermnesiaCLIContractTests",
            // Executable-target dependencies are supported by SwiftPM and force this binary to be
            // built before the contract test bundle, including clean and custom scratch builds.
            dependencies: ["HypermnesiaKit", "hypermnesia"]
        ),
    ]
)
