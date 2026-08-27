// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SQLCipher",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SQLCipher", targets: ["SQLCipher"]),
    ],
    targets: [
        .binaryTarget(name: "SQLCipher", path: "SQLCipher.xcframework"),
    ]
)
