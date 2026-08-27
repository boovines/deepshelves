// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemorySearch",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemorySearch", targets: ["MemorySearch"])],
    targets: [.target(name: "MemorySearch")]
)

