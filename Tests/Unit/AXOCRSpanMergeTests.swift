import Foundation
import MemoryContracts
import MemoryEnrichment
import XCTest

final class AXOCRSpanMergeTests: XCTestCase {
    func testMergePrefersAccessibilityAndIsByteStableAcrossInsertionOrder() throws {
        let frameID = UUID(uuidString: "32000000-0000-0000-0000-000000000001")!
        let shared = try NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1)
        let separate = try NormalizedRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1)
        let accessibility = [
            try span(
                id: 3, frameID: frameID, source: .accessibility,
                text: "Quarterly Plan", bounds: shared),
            try span(
                id: 2, frameID: frameID, source: .accessibility,
                text: "Same words", bounds: separate),
        ]
        let ocr = [
            try span(
                id: 9, frameID: frameID, source: .visionOCR,
                text: "quarterly   plan", bounds: shared, confidence: 0.99),
            try span(
                id: 8, frameID: frameID, source: .visionOCR,
                text: "OCR unique", bounds: nil, confidence: 0.91),
            try span(
                id: 7, frameID: frameID, source: .visionOCR,
                text: "Same words", bounds: shared, confidence: 0.95),
        ]

        let merger = AXOCRSpanMerger()
        let first = try merger.merge(
            frameID: frameID, accessibility: accessibility, ocr: ocr)
        let second = try merger.merge(
            frameID: frameID, accessibility: accessibility.reversed(), ocr: ocr.reversed())

        XCTAssertEqual(first, second)
        XCTAssertEqual(try canonicalBytes(first), try canonicalBytes(second))
        XCTAssertEqual(first.filter { comparisonKey($0.text) == "quarterly plan" }.count, 1)
        XCTAssertEqual(
            first.first { comparisonKey($0.text) == "quarterly plan" }?.source,
            .accessibility
        )
        XCTAssertEqual(first.filter { comparisonKey($0.text) == "same words" }.count, 2)
        XCTAssertEqual(
            Set(first.map { comparisonKey($0.text) }),
            [
                "quarterly plan", "same words", "ocr unique",
            ])
    }

    func testMergeDeduplicatesSameSourceAndUsesDeterministicBestOCRObservation() throws {
        let frameID = UUID(uuidString: "32000000-0000-0000-0000-000000000002")!
        let bounds = try NormalizedRect(x: 0.2, y: 0.3, width: 0.3, height: 0.1)
        let low = try span(
            id: 2, frameID: frameID, source: .visionOCR,
            text: "Local memory", bounds: bounds, confidence: 0.7)
        let high = try span(
            id: 9, frameID: frameID, source: .visionOCR,
            text: "LOCAL MEMORY", bounds: bounds, confidence: 0.98)

        let output = try AXOCRSpanMerger().merge(
            frameID: frameID, accessibility: [], ocr: [low, high])

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].id, high.id)
        XCTAssertEqual(output[0].confidence, 0.98)
    }

    func testMergeRejectsWrongFramesSourcesAndDropsSuppressedContent() throws {
        let frameID = UUID(uuidString: "32000000-0000-0000-0000-000000000003")!
        let otherFrameID = UUID(uuidString: "32000000-0000-0000-0000-000000000004")!
        let wrongFrame = try span(
            id: 1, frameID: otherFrameID, source: .accessibility,
            text: "wrong frame", bounds: nil)
        XCTAssertThrowsError(
            try AXOCRSpanMerger().merge(
                frameID: frameID, accessibility: [wrongFrame], ocr: []))

        let transcript = try span(
            id: 2, frameID: frameID, source: .transcript,
            text: "wrong source", bounds: nil)
        XCTAssertThrowsError(
            try AXOCRSpanMerger().merge(
                frameID: frameID, accessibility: [transcript], ocr: []))

        let suppressed = try span(
            id: 3, frameID: frameID, source: .visionOCR,
            text: "SECRET_SENTINEL", bounds: nil, confidence: 0.8,
            sensitivity: .suppressed)
        let output = try AXOCRSpanMerger().merge(
            frameID: frameID, accessibility: [], ocr: [suppressed])
        XCTAssertTrue(output.isEmpty)
        XCTAssertFalse(
            String(decoding: try canonicalBytes(output), as: UTF8.self).contains("SECRET"))
    }

    func testApprovedMetadataProjectionContainsOnlyNormalizedApprovedContext() throws {
        let foreground = try ForegroundContext(
            bundleID: "com.example.Editor",
            applicationName: "  Example   Editor ",
            processID: 481,
            windowTitle: "  Release\nPlan  ",
            windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        )
        let browser = try BrowserContext(
            family: .chrome,
            origin: BrowserOrigin(
                scheme: "https", host: "example.com", path: "/approved/path"),
            isPrivateContext: false
        )

        let projection = try ApprovedSearchMetadataProjector().project(
            foreground: foreground,
            browser: browser
        )

        XCTAssertEqual(projection.bundleID, "com.example.Editor")
        XCTAssertEqual(projection.applicationName, "Example Editor")
        XCTAssertEqual(projection.windowTitle, "Release Plan")
        XCTAssertEqual(projection.approvedURL, "https://example.com/approved/path")
        XCTAssertEqual(projection.host, "example.com")
        XCTAssertEqual(projection.path, "/approved/path")
        let bytes = try canonicalBytes(projection)
        let json = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(
            json.contains("481"), "Transient process identity must not enter this projection")
        XCTAssertFalse(json.contains("query"))
        XCTAssertFalse(json.contains("fragment"))
    }

    func testMetadataProjectionFailsClosedForPrivateOrUnapprovedURLSchemes() throws {
        let foreground = try ForegroundContext(
            bundleID: "com.example.Browser",
            applicationName: "Browser",
            processID: nil,
            windowTitle: nil,
            windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        )
        let privateContext = try BrowserContext(
            family: .chrome,
            origin: BrowserOrigin(scheme: "https", host: "secret.example", path: nil),
            isPrivateContext: true
        )
        let fileContext = try BrowserContext(
            family: .other,
            origin: BrowserOrigin(scheme: "file", host: "localhost", path: "/private"),
            isPrivateContext: false
        )

        XCTAssertThrowsError(
            try ApprovedSearchMetadataProjector().project(
                foreground: foreground, browser: privateContext))
        XCTAssertThrowsError(
            try ApprovedSearchMetadataProjector().project(
                foreground: foreground, browser: fileContext))
    }

    func testDecodedMetadataProjectionRevalidatesSensitiveURLComponents() throws {
        let projection = try ApprovedSearchMetadataProjection(
            bundleID: "com.example.Browser",
            applicationName: "Browser",
            windowTitle: "Approved title",
            browserFamily: .chrome,
            approvedURL: "https://example.com/approved/path",
            host: "example.com",
            path: "/approved/path"
        )
        let approvedBytes = try canonicalBytes(projection)
        let prohibitedJSON = String(decoding: approvedBytes, as: UTF8.self)
            .replacingOccurrences(of: "/approved/path", with: "/approved?token=secret")

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ApprovedSearchMetadataProjection.self,
                from: Data(prohibitedJSON.utf8)
            )
        )
    }

    func testCanonicalCorpusPassesS2DuplicateLossAndPermutationGates() throws {
        let frameID = UUID(uuidString: "32000000-0000-0000-0000-000000000006")!
        let merger = AXOCRSpanMerger()
        var mergedTokenCount = 0
        var duplicateCount = 0
        var groundTruthCount = 0
        var lostCount = 0

        for fixture in 0..<200 {
            let y = Double(fixture % 10) / 12.0
            let texts = (0..<4).map { "fixture-\(fixture)-token-\($0)" }
            let spans = try texts.enumerated().map { index, text in
                try span(
                    id: fixture * 10 + index, frameID: frameID, source: .visionOCR,
                    text: text,
                    bounds: NormalizedRect(
                        x: Double(index) / 5.0, y: y, width: 0.15, height: 0.05),
                    confidence: 0.9
                )
            }
            let ax = Array(spans.prefix(2)).enumerated().map { index, value in
                try! span(
                    id: 10_000 + fixture * 10 + index, frameID: frameID,
                    source: .accessibility, text: value.text.uppercased(),
                    bounds: value.bounds)
            }
            let merged = try merger.merge(frameID: frameID, accessibility: ax, ocr: spans)
            XCTAssertEqual(
                merged,
                try merger.merge(
                    frameID: frameID, accessibility: ax.reversed(), ocr: spans.reversed())
            )
            let keys = merged.map { comparisonKey($0.text) }
            mergedTokenCount += keys.count
            duplicateCount += keys.count - Set(keys).count
            for text in texts {
                groundTruthCount += 1
                if !keys.contains(comparisonKey(text)) { lostCount += 1 }
            }
        }

        XCTAssertLessThan(Double(duplicateCount) / Double(mergedTokenCount), 0.03)
        XCTAssertLessThan(Double(lostCount) / Double(groundTruthCount), 0.01)
        print(
            "LM032_METRIC fixtures=200 merged_tokens=\(mergedTokenCount) "
                + "duplicate_tokens=\(duplicateCount) ground_truth=\(groundTruthCount) "
                + "lost=\(lostCount)"
        )
    }
}

private func span(
    id: Int,
    frameID: UUID,
    source: TextSource,
    text: String,
    bounds: NormalizedRect?,
    confidence: Float? = nil,
    sensitivity: TextSensitivity = .normal
) throws -> TextSpan {
    try TextSpan(
        id: UUID(uuidString: String(format: "32000000-0000-0000-0000-%012d", id))!,
        frameID: frameID,
        source: source,
        text: text,
        bounds: bounds,
        confidence: confidence,
        languageCode: source == .visionOCR ? "en" : nil,
        sensitivity: sensitivity
    )
}

private func comparisonKey(_ text: String) -> String {
    TextSpan.normalize(text).lowercased(with: Locale(identifier: "en_US_POSIX"))
}

private func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
