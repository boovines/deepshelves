import Foundation
import XCTest

final class DependencyManifestTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testManifestPinsRequiredComponentsWithAuditableInputs() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.schemaVersion, 1)

        let requiredIDs: Set<String> = [
            "argmax-oss-swift",
            "coreml-mobileclip-s0",
            "grdb-sqlcipher",
            "mcp-swift-sdk",
            "sqlcipher-swift",
            "swift-testing-toolchain",
            "whisperkit-small-en",
            "xcodegen",
            "xctest-toolchain",
            "xcuitest-toolchain",
        ]
        XCTAssertTrue(requiredIDs.isSubset(of: Set(manifest.components.map(\.id))))

        for component in manifest.components {
            XCTAssertFalse(component.version.isEmpty, component.id)
            XCTAssertFalse(component.source.isEmpty, component.id)
            XCTAssertFalse(component.license.name.isEmpty, component.id)
            XCTAssertEqual(component.license.sha256.count, 64, component.id)
            XCTAssertFalse(component.updateProcedure.isEmpty, component.id)

            for artifact in component.artifacts {
                XCTAssertGreaterThan(artifact.expectedSize, 0, "\(component.id): \(artifact.path)")
                XCTAssertEqual(artifact.sha256.count, 64, "\(component.id): \(artifact.path)")
                XCTAssertFalse(artifact.url.isEmpty, "\(component.id): \(artifact.path)")
            }
        }
    }

    func testManifestHasNoFloatingProductionRevision() throws {
        let manifest = try loadManifest()
        for component in manifest.components where component.scope != "systemProvided" {
            XCTAssertNotEqual(component.revision, "main", component.id)
            XCTAssertNotEqual(component.revision, "master", component.id)
            XCTAssertGreaterThanOrEqual(component.revision.count, 7, component.id)
        }
    }

    func testModelAssetSetsAreCompleteAndRemainOutsideRuntimeDownloadPaths() throws {
        let components = Dictionary(
            uniqueKeysWithValues: try loadManifest().components.map { ($0.id, $0) }
        )
        let mobileCLIP = try XCTUnwrap(components["coreml-mobileclip-s0"])
        XCTAssertEqual(mobileCLIP.artifacts.count, 6)
        XCTAssertEqual(mobileCLIP.runtimeFetchPolicy, "forbidden")
        XCTAssertEqual(mobileCLIP.scope, "bundledModelShipping")

        let whisper = try XCTUnwrap(components["whisperkit-small-en"])
        XCTAssertEqual(whisper.artifacts.count, 19)
        XCTAssertEqual(whisper.runtimeFetchPolicy, "forbidden")
        XCTAssertEqual(whisper.scope, "optionalBuildTimeInstallOnly")
    }

    private func loadManifest() throws -> DependencyManifest {
        let url = repositoryRoot.appendingPathComponent("Dependencies/dependencies.json")
        return try JSONDecoder().decode(DependencyManifest.self, from: Data(contentsOf: url))
    }
}

private struct DependencyManifest: Decodable {
    let schemaVersion: Int
    let components: [DependencyComponent]
}

private struct DependencyComponent: Decodable {
    let id: String
    let version: String
    let revision: String
    let source: String
    let scope: String
    let runtimeFetchPolicy: String
    let license: DependencyLicense
    let artifacts: [DependencyArtifact]
    let updateProcedure: String
}

private struct DependencyLicense: Decodable {
    let name: String
    let sha256: String
}

private struct DependencyArtifact: Decodable {
    let path: String
    let url: String
    let expectedSize: Int
    let sha256: String
}
