// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemorySoftwareHEIC",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemorySoftwareHEIC", targets: ["MemorySoftwareHEIC"])],
    targets: [
        .target(
            name: "MemorySoftwareHEIC",
            resources: [.copy("Resources/SoftwareHEIC")]
        )
    ]
)
