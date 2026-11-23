// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RhinoCore",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "RhinoCore", targets: ["RhinoCore"]),
        .library(name: "RhinoControl", targets: ["RhinoControl"]),
        .library(name: "RhinoCLI", targets: ["RhinoCLI"]),
        .executable(name: "rhino", targets: ["rhino"]),
    ],
    dependencies: [
        // Only the command line tool uses it. The engine has no dependencies.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    ],
    targets: [
        // The engine: runs scripts. Knows nothing of windows or terminals.
        .target(
            name: "RhinoCore",
            resources: [
                .copy("Resources/prelude.js"),
                .copy("Resources/globals.d.ts"),
                .copy("Resources/Examples"),
            ]
        ),
        // What the app and the `rhino` tool say to each other, and the
        // socket they say it over. The app links this and nothing below it.
        .target(name: "RhinoControl"),
        // The `rhino` tool's commands and what they print.
        .target(
            name: "RhinoCLI",
            dependencies: ["RhinoControl", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "rhino", dependencies: ["RhinoCLI"]),
        .testTarget(name: "RhinoCoreTests", dependencies: ["RhinoCore"]),
        .testTarget(name: "RhinoControlTests", dependencies: ["RhinoControl"]),
        .testTarget(name: "RhinoCLITests", dependencies: ["RhinoCLI", "RhinoControl"]),
    ],
    swiftLanguageModes: [.v6]
)
