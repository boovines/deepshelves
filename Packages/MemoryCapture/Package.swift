// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryCapture",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryCapture", targets: ["MemoryCapture"])],
    targets: [.target(name: "MemoryCapture")]
)

