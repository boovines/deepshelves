// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryEnrichment",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryEnrichment", targets: ["MemoryEnrichment"])],
    dependencies: [
        .package(path: "../MemoryContracts"),
        .package(path: "../MemoryStore"),
    ],
    targets: [
        .target(
            name: "MemoryEnrichment",
            dependencies: ["MemoryContracts", "MemoryStore"],
            resources: [.copy("Resources/MobileCLIP-S0")]
        )
    ]
)
