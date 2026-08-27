import Foundation
import XCTest

final class DependencyClosurePrivacyTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testShippingTargetsContainNoUpdateTelemetryOrRemoteModelPackage() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let forbidden = [
            "Sparkle", "Sentry", "TelemetryDeck", "Firebase", "HuggingFace", "WhisperKit",
            "EventSource", "NIOHTTP", "URLSession",
        ]
        for token in forbidden {
            XCTAssertFalse(project.localizedCaseInsensitiveContains(token), token)
        }
    }

    func testEveryKnownNetworkCapableDependencyIsForbiddenFromShipping() throws {
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Dependencies/dependencies.json")
        )
        let manifest = try JSONDecoder().decode(PrivacyManifest.self, from: data)
        let networkCapable = manifest.components.filter(\.networkCapable)
        XCTAssertFalse(networkCapable.isEmpty)
        for component in networkCapable {
            XCTAssertEqual(component.scope, "forbiddenShipping", component.id)
            XCTAssertEqual(component.linkedShippingTargets, [], component.id)
        }
    }

    func testDependencyBootstrapIsExplicitBuildTimeOnly() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Dependencies/README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("No runtime code invokes this bootstrap"))
        XCTAssertTrue(readme.contains("--offline"))
        XCTAssertTrue(readme.contains("deny-all network"))
    }
}

private struct PrivacyManifest: Decodable {
    let components: [PrivacyComponent]
}

private struct PrivacyComponent: Decodable {
    let id: String
    let scope: String
    let networkCapable: Bool
    let linkedShippingTargets: [String]
}
