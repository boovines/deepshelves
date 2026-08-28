// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryEnrichment",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryEnrichment", targets: ["MemoryEnrichment"])],
    dependencies: [.package(path: "../MemoryContracts")],
    targets: [
        .target(
            name: "MemoryEnrichment",
            dependencies: ["MemoryContracts"],
            resources: [.copy("Resources/MobileCLIP-S0")]
        )
    ]
)
