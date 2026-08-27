// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryAgentAccess",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryAgentAccess", targets: ["MemoryAgentAccess"])],
    targets: [.target(name: "MemoryAgentAccess")]
)

