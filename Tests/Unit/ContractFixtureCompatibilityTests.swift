import CryptoKit
import Foundation
import MemoryContracts
import XCTest

final class ContractFixtureCompatibilityTests: XCTestCase {
    func testV1FixturesRoundTripToIdenticalCanonicalBytes() throws {
        let cases: [(String, (Data) throws -> Data)] = [
            (
                "capture-envelope.json",
                { try ContractJSON.roundTrip(CaptureEnvelope.self, fixture: $0) }
            ),
            ("media-chunk.json", { try ContractJSON.roundTrip(MediaChunk.self, fixture: $0) }),
            (
                "searchable-frame.json",
                { try ContractJSON.roundTrip(SearchableFrame.self, fixture: $0) }
            ),
            ("text-span.json", { try ContractJSON.roundTrip(TextSpan.self, fixture: $0) }),
            (
                "enrichment-artifact.json",
                { try ContractJSON.roundTrip(EnrichmentArtifact.self, fixture: $0) }
            ),
            ("access-policy.json", { try ContractJSON.roundTrip(AccessPolicy.self, fixture: $0) }),
            (
                "search-request.json",
                { try ContractJSON.roundTrip(SearchRequest.self, fixture: $0) }
            ),
            ("search-page.json", { try ContractJSON.roundTrip(SearchPage.self, fixture: $0) }),
            (
                "timeline-slice.json",
                { try ContractJSON.roundTrip(TimelineSlice.self, fixture: $0) }
            ),
            (
                "deletion-tombstone.json",
                { try ContractJSON.roundTrip(DeletionTombstone.self, fixture: $0) }
            ),
            (
                "processing-job.json",
                { try ContractJSON.roundTrip(ProcessingJob.self, fixture: $0) }
            ),
        ]

        for (name, roundTrip) in cases {
            let fixture = try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
            XCTAssertEqual(
                try roundTrip(fixture), fixture, "fixture changed byte semantics: \(name)")
        }
    }

    func testFixtureManifestPinsSyntheticSourceLicenseAndSHA256() throws {
        let manifestURL =
            fixtureDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.generatorVersion, "contract-fixture-generator-v1")
        XCTAssertEqual(manifest.fixtures.count, 11)
        for entry in manifest.fixtures {
            XCTAssertEqual(entry.source, "synthetic")
            XCTAssertEqual(entry.license, "CC0-1.0")
            XCTAssertFalse(entry.semanticLabels.isEmpty)
            let data = try Data(
                contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(
                    entry.path))
            XCTAssertEqual(SHA256.hash(data: data).hex, entry.sha256)
        }
    }

    func testV1ReaderIgnoresUnknownAdditiveFields() throws {
        let fixture = try fixtureData("capture-envelope.json")
        let expected = try ContractJSON.decode(CaptureEnvelope.self, from: fixture)
        let extended = try mutateJSONObject(fixture) { root in
            root["futureAdditiveField"] = ["ignored": true]
        }

        XCTAssertEqual(try ContractJSON.decode(CaptureEnvelope.self, from: extended), expected)
    }

    func testUnknownEnumCaseFailsClosed() throws {
        let malformed = try mutateJSONObject(fixtureData("media-chunk.json")) { root in
            root["codec"] = "futureCodec"
        }

        XCTAssertThrowsError(try ContractJSON.decode(MediaChunk.self, from: malformed)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testArchivePathTraversalFailsClosed() throws {
        let malformed = try mutateJSONObject(fixtureData("media-chunk.json")) { root in
            root["relativePath"] = "../outside.mov"
        }

        XCTAssertThrowsError(try ContractJSON.decode(MediaChunk.self, from: malformed)) { error in
            XCTAssertEqual((error as? ContractValidationError)?.violation, .pathTraversal)
        }
    }

    func testInvalidHalfOpenOrOverlongIntervalFailsClosed() throws {
        let empty = try mutateJSONObject(fixtureData("media-chunk.json")) { root in
            root["endedAt"] = root["startedAt"]
        }
        let overlong = try mutateJSONObject(fixtureData("media-chunk.json")) { root in
            root["endedAt"] = "2026-05-02T05:33:51.000Z"
        }

        for malformed in [empty, overlong] {
            XCTAssertThrowsError(try ContractJSON.decode(MediaChunk.self, from: malformed)) {
                error in
                XCTAssertTrue(error is ContractValidationError)
            }
        }
    }

    func testNoncanonicalWallClockTimestampFailsClosed() throws {
        let malformed = try mutateJSONObject(fixtureData("media-chunk.json")) { root in
            root["startedAt"] = "2026-05-02T05:33:20Z"
        }

        XCTAssertThrowsError(try ContractJSON.decode(MediaChunk.self, from: malformed)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testMalformedAgentPoliciesFailClosed() throws {
        let fixture = try fixtureData("access-policy.json")
        let notUserCreated = try mutateJSONObject(fixture) { $0["createdByUser"] = false }
        let unboundedResults = try mutateJSONObject(fixture) { $0["maxResults"] = 101 }
        let overlongHistory = try mutateJSONObject(fixture) { root in
            var interval = try XCTUnwrap(root["allowedInterval"] as? [String: Any])
            interval["duration"] = 31 * 24 * 60 * 60
            root["allowedInterval"] = interval
        }
        let overlongSession = try mutateJSONObject(fixture) { root in
            root["expiresAt"] = "2026-05-04T06:33:20.001Z"
        }

        for malformed in [notUserCreated, unboundedResults, overlongHistory, overlongSession] {
            XCTAssertThrowsError(try ContractJSON.decode(AccessPolicy.self, from: malformed)) {
                error in
                XCTAssertTrue(error is ContractValidationError)
            }
        }
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Contracts/v1", isDirectory: true)
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
    }

    private func mutateJSONObject(
        _ data: Data,
        mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try mutation(&root)
        return try JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

private struct FixtureManifest: Decodable {
    let schemaVersion: Int
    let generatorVersion: String
    let fixtures: [FixtureManifestEntry]
}

private struct FixtureManifestEntry: Decodable {
    let path: String
    let source: String
    let license: String
    let sha256: String
    let semanticLabels: [String]
}

extension SHA256.Digest {
    fileprivate var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
