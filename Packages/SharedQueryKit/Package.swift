// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharedQueryKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SharedQueryKit", targets: ["SharedQueryKit"])],
    dependencies: [
        .package(path: "../MemoryContracts"),
    ],
    targets: [
        .target(
            name: "SharedQueryKit",
            dependencies: ["MemoryContracts"]
        ),
        .testTarget(
            name: "SharedQueryKitTests",
            dependencies: ["MemoryContracts", "SharedQueryKit"]
        ),
    ]
)
