// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MCPStdio",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MCPStdio", targets: ["MCPStdio"])],
    targets: [
        .target(name: "MCPStdio"),
        .testTarget(name: "MCPStdioTests", dependencies: ["MCPStdio"]),
    ]
)
