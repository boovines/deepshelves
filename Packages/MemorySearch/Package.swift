// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemorySearch",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemorySearch", targets: ["MemorySearch"])],
    dependencies: [
        .package(path: "../MemoryContracts"),
        .package(path: "../MemoryStore"),
    ],
    targets: [
        .target(name: "MemorySearch", dependencies: ["MemoryContracts", "MemoryStore"]),
        .testTarget(name: "MemorySearchTests", dependencies: ["MemorySearch"]),
    ]
)
