// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryStore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MemoryStore", targets: ["MemoryStore"])],
    dependencies: [
        .package(
            path: "../../.build/Dependencies/GRDB.swift-a285e4ca87ec6b3584c97b0ec25fc61fec02de60"),
        .package(path: "../MemoryContracts"),
    ],
    targets: [
        .target(
            name: "MemoryStore",
            dependencies: [
                "MemoryContracts",
                .product(
                    name: "GRDB",
                    package: "GRDB.swift-a285e4ca87ec6b3584c97b0ec25fc61fec02de60"
                ),
            ]
        )
    ]
)
