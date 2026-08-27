// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryStore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryStore", targets: ["MemoryStore"])],
    targets: [.target(name: "MemoryStore")]
)

