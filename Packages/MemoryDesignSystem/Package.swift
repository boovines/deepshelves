// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryDesignSystem",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryDesignSystem", targets: ["MemoryDesignSystem"])],
    targets: [.target(name: "MemoryDesignSystem")]
)

