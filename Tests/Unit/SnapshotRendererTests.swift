import AppKit
import Foundation
import MemoryDesignSystem
import SwiftUI
import XCTest

@MainActor
final class SnapshotRendererTests: XCTestCase {
    func testCanonicalConfigurationMatrixCoversScaleAppearanceAndSize() {
        let configurations = MemorySnapshotConfiguration.canonicalMatrix
        XCTAssertEqual(configurations.count, 12)
        XCTAssertEqual(Set(configurations.map(\.fileStem)).count, 12)
        XCTAssertEqual(Set(configurations.map(\.scale)), [1, 2])
        XCTAssertEqual(Set(configurations.map(\.appearance)), [.light, .dark, .increasedContrast])
        XCTAssertEqual(Set(configurations.map(\.size)), [.default, .minimum])

        for configuration in configurations {
            XCTAssertEqual(
                configuration.pixelWidth,
                Int(configuration.logicalWidth * configuration.scale)
            )
            XCTAssertEqual(
                configuration.pixelHeight,
                Int(configuration.logicalHeight * configuration.scale)
            )
        }
    }

    func testOffscreenHostingRendererProducesExactDeterministicPixels() throws {
        let configuration = MemorySnapshotConfiguration(
            size: .custom(width: 96, height: 64, name: "unit"),
            appearance: .dark,
            scale: 2
        )
        let renderer = MemorySnapshotRenderer()
        let view = ZStack {
            MemoryColorToken.surfaceWindow.color
            RoundedRectangle(cornerRadius: MemoryRadius.control)
                .fill(MemoryColorToken.accent.color)
                .frame(width: 40, height: 24)
        }

        let first = try renderer.pngData(of: view, configuration: configuration)
        let second = try renderer.pngData(of: view, configuration: configuration)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: first))

        XCTAssertEqual(bitmap.pixelsWide, 192)
        XCTAssertEqual(bitmap.pixelsHigh, 128)
        XCTAssertEqual(first, second)
    }

    func testInvalidSnapshotConfigurationFailsClosed() {
        XCTAssertThrowsError(
            try MemorySnapshotConfiguration.validated(
                size: .custom(width: 0, height: 64, name: "invalid"),
                appearance: .light,
                scale: 2
            )
        )
        XCTAssertThrowsError(
            try MemorySnapshotConfiguration.validated(
                size: .minimum,
                appearance: .light,
                scale: 1.5
            )
        )
    }

    func testCheckedInManifestAndIndexCoverEveryApprovedBaseline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let results = root.appending(path: "Results/LM-013")
        let manifestData = try Data(contentsOf: results.appending(path: "snapshot-manifest.json"))
        let manifest = try JSONDecoder().decode(MemorySnapshotManifest.self, from: manifestData)
        let index = try String(contentsOf: results.appending(path: "snapshot-index.html"), encoding: .utf8)

        XCTAssertEqual(manifest.configurations, MemorySnapshotConfiguration.canonicalMatrix)
        XCTAssertEqual(manifest.artifacts.count, 12)
        XCTAssertTrue(try manifest.verifyArtifacts(relativeTo: root))
        XCTAssertFalse(index.contains("http://"))
        XCTAssertFalse(index.contains("https://"))
        for artifact in manifest.artifacts {
            XCTAssertTrue(index.contains(artifact.path))
        }
    }
}
