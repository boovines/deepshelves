// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryTestSupport",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryTestSupport", targets: ["MemoryTestSupport"])],
    targets: [.target(name: "MemoryTestSupport")]
)

