import MemoryEnrichment
import XCTest

final class ContextVisionIntegrationTests: XCTestCase {
    func testVisionRecognizesRenderedGroundTruthWithBounds() async throws {
        let fixture = try XCTUnwrap(S2FixtureCatalog.make(seed: 0xD335_5EED).ocrFixtures.first)
        let rendered = try S2OCRRenderer.render(fixture)
        let observations = try await VisionContextOCR().recognize(rendered.image)
        let metrics = OCRRecallScorer.score(
            groundTruth: rendered.groundTruth,
            observations: observations,
            minimumIntersectionOverUnion: 0.5
        )

        XCTAssertGreaterThanOrEqual(metrics.wordRecall, 0.90)
        XCTAssertEqual(metrics.totalGroundTruthWords, 4)
        XCTAssertGreaterThanOrEqual(metrics.matchedGroundTruthWords, 4)
        XCTAssertTrue(observations.allSatisfy { $0.bounds != nil })
        XCTAssertTrue(observations.allSatisfy { ($0.confidence ?? 0) > 0 })
    }
}
