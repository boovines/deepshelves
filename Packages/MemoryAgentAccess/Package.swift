// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryAgentAccess",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryAgentAccess", targets: ["MemoryAgentAccess"])],
    dependencies: [
        .package(path: "../MemoryContracts"),
        .package(path: "../MCPStdio"),
        .package(path: "../SharedQueryKit"),
    ],
    targets: [
        .target(
            name: "MemoryAgentAccess",
            dependencies: ["MemoryContracts", "MCPStdio", "SharedQueryKit"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "MemoryAgentAccessTests",
            dependencies: ["MemoryAgentAccess", "MemoryContracts", "MCPStdio", "SharedQueryKit"]
        ),
    ]
)
