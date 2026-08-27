// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryEnrichment",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryEnrichment", targets: ["MemoryEnrichment"])],
    targets: [.target(name: "MemoryEnrichment")]
)

