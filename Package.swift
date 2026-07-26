// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Browser",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Browser", targets: ["BrowserApp"])
    ],
    targets: [
        .target(
            name: "BrowserCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "BrowserEngine",
            dependencies: ["BrowserCore"]
        ),
        .target(
            name: "BrowserPersistence",
            dependencies: ["BrowserCore"]
        ),
        .target(
            name: "BrowserAI",
            dependencies: ["BrowserCore"]
        ),
        .target(
            name: "BrowserUI",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserAI"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "BrowserApp",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserPersistence", "BrowserUI", "BrowserAI"]
        ),
        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore"]
        ),
        .testTarget(
            name: "BrowserPersistenceTests",
            dependencies: ["BrowserCore", "BrowserPersistence"]
        ),
        .testTarget(
            name: "BrowserAITests",
            dependencies: ["BrowserAI"]
        ),
        .testTarget(
            name: "BrowserUITests",
            dependencies: ["BrowserUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
