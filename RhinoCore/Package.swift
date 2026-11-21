// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RhinoCore",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "RhinoCore", targets: ["RhinoCore"]),
    ],
    targets: [
        .target(
            name: "RhinoCore",
            resources: [
                .copy("Resources/prelude.js"),
                .copy("Resources/globals.d.ts"),
                .copy("Resources/Examples"),
            ]
        ),
        .testTarget(name: "RhinoCoreTests", dependencies: ["RhinoCore"]),
    ],
    swiftLanguageModes: [.v6]
)
