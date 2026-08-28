// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryCapture",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MemoryCapture", targets: ["MemoryCapture"]),
        .executable(name: "LM028SoakHarness", targets: ["LM028SoakHarness"]),
    ],
    dependencies: [
        .package(path: "../MemoryContracts"),
        .package(path: "../MemorySoftwareHEIC"),
    ],
    targets: [
        .target(
            name: "MemoryCapture",
            dependencies: ["MemoryContracts", "MemorySoftwareHEIC"]
        ),
        .executableTarget(
            name: "LM028SoakHarness",
            dependencies: ["MemoryCapture"]
        ),
    ]
)
