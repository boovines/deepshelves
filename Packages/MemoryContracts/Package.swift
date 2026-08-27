// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryContracts",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryContracts", targets: ["MemoryContracts"])],
    targets: [.target(name: "MemoryContracts")]
)

