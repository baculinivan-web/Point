// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Browser",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Browser", targets: ["BrowserApp"]),
        .executable(name: "point-browser-mcp", targets: ["PointBrowserMCP"])
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
            name: "BrowserAutomation",
            dependencies: ["BrowserCore"]
        ),
        .target(
            name: "BrowserAI",
            dependencies: ["BrowserCore", "BrowserAutomation"]
        ),
        .target(
            name: "BrowserUI",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserAI", "BrowserAutomation"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "BrowserApp",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserPersistence", "BrowserUI", "BrowserAI", "BrowserAutomation"]
        ),
        .executableTarget(
            name: "PointBrowserMCP"
        ),
        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore"]
        ),
        .testTarget(
            name: "BrowserEngineTests",
            dependencies: ["BrowserEngine"]
        ),
        .testTarget(
            name: "BrowserPersistenceTests",
            dependencies: ["BrowserCore", "BrowserPersistence"]
        ),
        .testTarget(
            name: "BrowserAITests",
            dependencies: ["BrowserAI", "BrowserAutomation"]
        ),
        .testTarget(
            name: "BrowserUITests",
            dependencies: ["BrowserCore", "BrowserUI", "BrowserPersistence"]
        ),
        .testTarget(
            name: "BrowserAutomationTests",
            dependencies: ["BrowserAutomation"]
        )
    ],
    swiftLanguageModes: [.v6]
)
