import Foundation
import MemoryEnrichment
import XCTest

final class VectorSpikeCoreTests: XCTestCase {
    func testModelResourceIntegrityFailsClosedOnHashMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "model-integrity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appending(path: "fixture.bin")
        try Data("approved model bytes".utf8).write(to: artifact)

        let correct = try ModelResourceIntegrity.sha256(of: artifact)
        let manifest = ModelResourceManifest(
            version: "fixture-v1",
            artifacts: [ModelResourceArtifact(relativePath: "fixture.bin", sha256: correct)]
        )
        XCTAssertNoThrow(try ModelResourceIntegrity.verify(manifest, root: root))

        try Data("corrupted".utf8).write(to: artifact)
        XCTAssertThrowsError(try ModelResourceIntegrity.verify(manifest, root: root)) { error in
            XCTAssertEqual(error as? ModelResourceError, .hashMismatch("fixture.bin"))
        }
    }

    func testExactVectorFileRejectsTruncatedPayloadBeforeScoring() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "vectors-\(UUID().uuidString).f16")
        defer { try? FileManager.default.removeItem(at: url) }
        let vectors: [[Float]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
        ]
        try ExactVectorFileWriter.write(
            vectors: vectors,
            modelVersion: "fixture-model",
            to: url
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ExactVectorFileHeader.byteCount + 5))
        try handle.close()

        XCTAssertThrowsError(try ExactVectorScanner(url: url)) { error in
            XCTAssertEqual(error as? ExactVectorError, .truncatedPayload)
        }
    }

    func testExactVectorScanMatchesScalarReferenceAndUsesStableOrdering() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "vectors-\(UUID().uuidString).f16")
        defer { try? FileManager.default.removeItem(at: url) }
        let vectors: [[Float]] = [
            [1, 0, 0, 0],
            [0.5, 0.5, 0.5, 0.5],
            [1, 0, 0, 0],
            [0, 1, 0, 0],
        ]
        try ExactVectorFileWriter.write(
            vectors: vectors,
            modelVersion: "fixture-model",
            to: url
        )
        let scanner = try ExactVectorScanner(url: url)
        let query: [Float] = [1, 0, 0, 0]
        let results = try scanner.search(query: query, range: 0 ..< 4, limit: 4)

        XCTAssertEqual(results.map(\.index), [0, 2, 1, 3])
        var expected: [VectorSearchResult] = []
        for (index, vector) in vectors.enumerated() {
            var score: Float = 0
            for component in vector.indices {
                score += query[component] * vector[component]
            }
            expected.append(VectorSearchResult(index: index, score: score))
        }
        expected.sort {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
        XCTAssertEqual(results.count, expected.count)
        for (actual, reference) in zip(results, expected) {
            XCTAssertEqual(actual.index, reference.index)
            XCTAssertEqual(actual.score, reference.score, accuracy: 1e-3)
        }
    }
}
