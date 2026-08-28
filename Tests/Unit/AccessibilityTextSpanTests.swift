import Foundation
import MemoryCapture
import MemoryContracts
import XCTest

final class AccessibilityTextSpanTests: XCTestCase {
    func testNormalizationGoldensEmitCanonicalAccessibilitySpans() throws {
        let fixture = try loadNormalizationFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 12)

        for (index, golden) in fixture.cases.enumerated() {
            let spans = try AccessibilityTextSpanEmitter().emit(
                elements: [projected(title: golden.raw, path: [index])],
                windowBounds: fixtureWindowBounds,
                frameID: frameID,
                idProvider: { deterministicUUID($0) }
            )
            XCTAssertEqual(spans.map(\.text), [golden.expected], golden.id)
            XCTAssertEqual(spans.first?.source, .accessibility, golden.id)
            XCTAssertNil(spans.first?.confidence, golden.id)
            XCTAssertNil(spans.first?.languageCode, golden.id)
            XCTAssertEqual(spans.first?.sensitivity, .normal, golden.id)
        }
    }

    func testSecureFieldValueIsSuppressedAgainBeforeTextSpanEmission() throws {
        let secret = "LM030_SECURE_SENTINEL_DO_NOT_PERSIST"
        let element = ProjectedAccessibilityElement(
            role: "AXSecureTextField",
            subrole: nil,
            title: "Password",
            value: secret,
            nodeDescription: "Account credential",
            help: nil,
            identifier: secret,
            bounds: PointRect(x: 120, y: 120, width: 300, height: 30),
            isEnabled: true,
            isFocused: true,
            hierarchyPath: [2],
            signature: secret
        )

        let spans = try AccessibilityTextSpanEmitter().emit(
            elements: [element],
            windowBounds: fixtureWindowBounds,
            frameID: frameID,
            idProvider: { deterministicUUID($0) }
        )
        let encoded = String(decoding: try JSONEncoder().encode(spans), as: UTF8.self)

        XCTAssertEqual(Set(spans.map(\.text)), ["Password", "Account credential"])
        XCTAssertFalse(encoded.contains(secret))
    }

    func testDuplicatesCollapseByCanonicalTextAndOverlappingBounds() throws {
        let elements = [
            projected(
                title: " Cafe\u{301} ",
                bounds: PointRect(x: 120, y: 120, width: 300, height: 30),
                path: [0]
            ),
            projected(
                title: "Café",
                bounds: PointRect(x: 121, y: 120, width: 300, height: 30),
                path: [1]
            ),
            projected(
                title: "Café",
                bounds: PointRect(x: 600, y: 500, width: 200, height: 30),
                path: [2]
            ),
            projected(title: "Unplaced duplicate", path: [3]),
            projected(title: " Unplaced   duplicate ", path: [4]),
        ]

        let spans = try AccessibilityTextSpanEmitter().emit(
            elements: elements.reversed(),
            windowBounds: fixtureWindowBounds,
            frameID: frameID,
            idProvider: { deterministicUUID($0) }
        )

        XCTAssertEqual(spans.filter { $0.text == "Café" }.count, 2)
        XCTAssertEqual(spans.filter { $0.text == "Unplaced duplicate" }.count, 1)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans.map(\.id), (0..<3).map(deterministicUUID))
    }

    func testBoundsAreClippedAndNormalizedToAcceptedWindow() throws {
        let partiallyOutside = projected(
            title: "Clipped",
            bounds: PointRect(x: 50, y: 60, width: 200, height: 100),
            path: [0]
        )
        let fullyOutside = projected(
            title: "No bounds",
            bounds: PointRect(x: 2_000, y: 2_000, width: 100, height: 100),
            path: [1]
        )

        let spans = try AccessibilityTextSpanEmitter().emit(
            elements: [partiallyOutside, fullyOutside],
            windowBounds: fixtureWindowBounds,
            frameID: frameID,
            idProvider: { deterministicUUID($0) }
        )

        let clipped = try XCTUnwrap(spans.first { $0.text == "Clipped" }?.bounds)
        XCTAssertEqual(clipped.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(clipped.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(clipped.width, 150.0 / 900.0, accuracy: 0.000_001)
        XCTAssertEqual(clipped.height, 80.0 / 640.0, accuracy: 0.000_001)
        XCTAssertNil(spans.first { $0.text == "No bounds" }?.bounds)
    }

    func testEmptyAndWhitespaceOnlyFieldsDoNotProduceRows() throws {
        let element = ProjectedAccessibilityElement(
            role: "AXStaticText",
            subrole: nil,
            title: " \n\t ",
            value: nil,
            nodeDescription: "",
            help: nil,
            identifier: "ignored-identifier",
            bounds: nil,
            isEnabled: nil,
            isFocused: nil,
            hierarchyPath: [0],
            signature: "AXStaticText|||0"
        )
        let spans = try AccessibilityTextSpanEmitter().emit(
            elements: [element],
            windowBounds: fixtureWindowBounds,
            frameID: frameID,
            idProvider: { deterministicUUID($0) }
        )
        XCTAssertTrue(spans.isEmpty)
    }

    private let frameID = UUID(uuidString: "30000000-0000-0000-0000-000000000030")!
    private let fixtureWindowBounds = PointRect(x: 100, y: 80, width: 900, height: 640)

    private func projected(
        title: String,
        bounds: PointRect? = nil,
        path: [Int]
    ) -> ProjectedAccessibilityElement {
        ProjectedAccessibilityElement(
            role: "AXStaticText",
            subrole: nil,
            title: title,
            value: nil,
            nodeDescription: nil,
            help: nil,
            identifier: nil,
            bounds: bounds,
            isEnabled: true,
            isFocused: false,
            hierarchyPath: path,
            signature: "AXStaticText|||\(path.map(String.init).joined(separator: "."))"
        )
    }

    private func deterministicUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index + 1))!
    }

    private func loadNormalizationFixture() throws -> NormalizationFixture {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM030/normalization-goldens.json")
        return try JSONDecoder().decode(
            NormalizationFixture.self,
            from: Data(contentsOf: sourceURL)
        )
    }
}

private struct NormalizationFixture: Decodable {
    let schemaVersion: Int
    let cases: [NormalizationGolden]
}

private struct NormalizationGolden: Decodable {
    let id: String
    let raw: String
    let expected: String
}
