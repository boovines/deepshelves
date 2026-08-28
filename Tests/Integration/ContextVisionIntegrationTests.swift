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

    func testProductionVisionRecognizerMeetsFullCanonicalCorpusGates() async throws {
        let fixtures = S2FixtureCatalog.make(seed: 0xD335_5EED).ocrFixtures
        let recognizer = AppleVisionTextRecognizer()
        var highContrastMatches = 0
        var highContrastWords = 0
        var fullMatches = 0
        var fullWords = 0
        var latencies: [Double] = []

        for fixture in fixtures {
            let rendered = try S2OCRRenderer.render(fixture)
            let input = OCRFrameInput(
                image: rendered.image,
                orientation: .up,
                sourcePixelWidth: S2OCRRenderer.width,
                sourcePixelHeight: S2OCRRenderer.height,
                processedRegion: OCRPixelRect(
                    x: 0,
                    y: 0,
                    width: Double(S2OCRRenderer.width),
                    height: Double(S2OCRRenderer.height)
                )
            )
            let started = ContinuousClock.now
            let raw = try await recognizer.recognize(input)
            latencies.append(started.duration(to: .now).milliseconds)
            let observations = raw.map {
                ContextTextObservation(
                    text: $0.text,
                    source: .visionOCR,
                    bounds: ContextRect(
                        x: $0.visionBounds.x,
                        y: $0.visionBounds.y,
                        width: $0.visionBounds.width,
                        height: $0.visionBounds.height
                    ),
                    confidence: Double($0.confidence)
                )
            }
            let metrics = OCRRecallScorer.score(
                groundTruth: rendered.groundTruth,
                observations: observations,
                minimumIntersectionOverUnion: 0.5
            )
            fullMatches += metrics.matchedGroundTruthWords
            fullWords += metrics.totalGroundTruthWords
            if fixture.isHighContrastLatin {
                highContrastMatches += metrics.matchedGroundTruthWords
                highContrastWords += metrics.totalGroundTruthWords
            }
            XCTAssertTrue(raw.allSatisfy { $0.confidence > 0 && $0.languageCode != nil })
        }

        let highContrastRecall = Double(highContrastMatches) / Double(highContrastWords)
        let fullRecall = Double(fullMatches) / Double(fullWords)
        let sortedLatency = latencies.sorted()
        let p95 = sortedLatency[Int(Double(sortedLatency.count - 1) * 0.95)]
        print(
            "LM031_METRIC fixtures=\(fixtures.count) high_contrast_recall=\(highContrastRecall) "
                + "full_recall=\(fullRecall) p95_ms=\(p95)"
        )
        XCTAssertGreaterThanOrEqual(highContrastRecall, 0.90)
        XCTAssertGreaterThanOrEqual(fullRecall, 0.82)
    }
}

extension Duration {
    fileprivate var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
