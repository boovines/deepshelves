import Foundation
import MemoryContracts
import XCTest

@testable import MemorySearch

@MainActor
final class MomentDetailModelTests: XCTestCase {
    func testRapidSelectionPublishesOnlyTheExactLatestFrame() async throws {
        let first = try result(suffix: 1)
        let second = try result(suffix: 2)
        let repository = MomentDetailRepository(
            capacityBytes: 64,
            loader: MomentDetailLoader { result in
                if result.frameID == first.frameID {
                    try await Task.sleep(for: .milliseconds(30))
                    return try MomentDetailRaster(width: 1, height: 1, rgba8: [255, 0, 0, 255])
                }
                try await Task.sleep(for: .milliseconds(1))
                return try MomentDetailRaster(width: 1, height: 1, rgba8: [0, 255, 0, 255])
            }
        )
        let model = MomentDetailSessionModel(repository: repository)

        async let firstSelection: Void = model.select(first)
        try await Task.sleep(for: .milliseconds(2))
        async let secondSelection: Void = model.select(second)
        _ = await (firstSelection, secondSelection)

        XCTAssertEqual(
            model.state,
            .ready(
                MomentDetailFrame(
                    identity: try XCTUnwrap(MomentDetailIdentity(result: second)),
                    raster: try MomentDetailRaster(
                        width: 1,
                        height: 1,
                        rgba8: [0, 255, 0, 255]
                    )
                )
            )
        )
    }

    func testFrameSteppingUsesStableSearchOrderAndStopsAtBoundaries() throws {
        let results = try [result(suffix: 1), result(suffix: 2), result(suffix: 3)]

        XCTAssertEqual(
            MomentDetailSequence.adjacent(
                to: results[1].frameID,
                direction: .previous,
                in: results
            )?.frameID,
            results[0].frameID
        )
        XCTAssertEqual(
            MomentDetailSequence.adjacent(
                to: results[1].frameID,
                direction: .next,
                in: results
            )?.frameID,
            results[2].frameID
        )
        XCTAssertNil(
            MomentDetailSequence.adjacent(
                to: results[0].frameID,
                direction: .previous,
                in: results
            )
        )
        XCTAssertNil(
            MomentDetailSequence.adjacent(
                to: results[2].frameID,
                direction: .next,
                in: results
            )
        )
    }

    func testCanvasTransformBoundsZoomAndPanToVisibleContent() {
        let fitted = MomentCanvasTransform.identity
            .zoomed(to: 0.25)
            .panned(byX: 80, y: -90, viewportWidth: 400, viewportHeight: 300)
        XCTAssertEqual(fitted, .identity)

        let zoomed = MomentCanvasTransform.identity
            .zoomed(to: 20)
            .panned(byX: 9_000, y: -9_000, viewportWidth: 400, viewportHeight: 300)
        XCTAssertEqual(zoomed.scale, 8)
        XCTAssertEqual(zoomed.offsetX, 1_400)
        XCTAssertEqual(zoomed.offsetY, -1_050)

        XCTAssertEqual(zoomed.reset(), .identity)
    }

    func testTypedCorruptMediaFailureCanRetryTheSameExactSource() async throws {
        let result = try result(suffix: 4)
        let probe = MomentDetailLoaderProbe()
        let model = MomentDetailSessionModel(
            repository: MomentDetailRepository(
                capacityBytes: 64,
                loader: MomentDetailLoader { result in
                    try await probe.load(result)
                }
            )
        )

        await model.select(result)
        XCTAssertEqual(model.state, .failure(frameID: result.frameID, reason: .corruptMedia))

        await model.retry()

        guard case .ready(let frame) = model.state else {
            return XCTFail("retry must publish the exact selected frame")
        }
        XCTAssertEqual(frame.identity, MomentDetailIdentity(result: result))
        XCTAssertEqual(frame.raster.rgba8, [0, 0, 255, 255])
        let requestedIDs = await probe.requestedFrameIDs()
        XCTAssertEqual(requestedIDs, [result.frameID, result.frameID])
    }

    func testDecodedFrameCacheEvictsByByteCapacity() async throws {
        let first = try result(suffix: 5)
        let second = try result(suffix: 6)
        let probe = MomentDetailCountingLoader()
        let repository = MomentDetailRepository(
            capacityBytes: 4,
            loader: MomentDetailLoader { result in try await probe.load(result) }
        )

        _ = try await repository.frame(for: first)
        _ = try await repository.frame(for: second)
        let cachedAfterSecond = await repository.cachedCount()
        XCTAssertEqual(cachedAfterSecond, 1)
        _ = try await repository.frame(for: first)

        let loadCount = await probe.loadCount()
        let finalCachedCount = await repository.cachedCount()
        XCTAssertEqual(loadCount, 3)
        XCTAssertEqual(finalCachedCount, 1)
    }

    func testCachedFrameIsNeverReturnedAfterSourceIntegrityChanges() async throws {
        let result = try result(suffix: 7)
        let integrity = MomentDetailIntegrityProbe()
        let repository = MomentDetailRepository(
            capacityBytes: 64,
            validator: MomentDetailValidator { result in
                try await integrity.validate(result)
            },
            loader: MomentDetailLoader { _ in
                try MomentDetailRaster(width: 1, height: 1, rgba8: [1, 2, 3, 255])
            }
        )
        _ = try await repository.frame(for: result)
        await integrity.markTampered()

        do {
            _ = try await repository.frame(for: result)
            XCTFail("a cached frame must still revalidate its exact source")
        } catch {
            XCTAssertEqual(error as? MomentDetailError, .integrityMismatch)
        }
    }

    private func result(suffix: Int) throws -> SearchResult {
        try SearchResult(
            frameID: UUID(uuidString: String(format: "43000000-0000-4000-8000-%012d", suffix))!,
            capturedAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(suffix)),
            foreground: ForegroundContext(
                bundleID: "com.apple.Safari",
                applicationName: "Safari",
                processID: nil,
                windowTitle: "Detail \(suffix)",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: nil,
            mediaLocator: .archiveRelativePath("media/detail-\(suffix).heic"),
            evidence: [SearchEvidence(source: .title, matchedText: "Detail", score: 1)],
            textRank: suffix,
            visualRank: nil,
            fusedScore: 1
        )
    }
}

private actor MomentDetailLoaderProbe {
    private var frameIDs: [UUID] = []

    func load(_ result: SearchResult) throws -> MomentDetailRaster {
        frameIDs.append(result.frameID)
        if frameIDs.count == 1 { throw MomentDetailError.corruptMedia }
        return try MomentDetailRaster(width: 1, height: 1, rgba8: [0, 0, 255, 255])
    }

    func requestedFrameIDs() -> [UUID] { frameIDs }
}

private actor MomentDetailCountingLoader {
    private var count = 0

    func load(_ result: SearchResult) throws -> MomentDetailRaster {
        count += 1
        return try MomentDetailRaster(
            width: 1,
            height: 1,
            rgba8: [UInt8(result.textRank ?? 0), 0, 0, 255]
        )
    }

    func loadCount() -> Int { count }
}

private actor MomentDetailIntegrityProbe {
    private var tampered = false

    func markTampered() { tampered = true }

    func validate(_ result: SearchResult) throws {
        if tampered { throw MomentDetailError.integrityMismatch }
    }
}
