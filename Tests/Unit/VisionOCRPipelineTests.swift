import CoreGraphics
import Foundation
import MemoryContracts
import MemoryEnrichment
import XCTest

final class VisionOCRPipelineTests: XCTestCase {
    func testOrientationScaleConfidenceLanguageAndBoundsEmitVisionTextSpans() async throws {
        let recognizer = FixtureVisionRecognizer(observations: [
            OCRRawObservation(
                text: "  Café\nplan  ",
                confidence: 0.94,
                languageCode: "fr",
                visionBounds: OCRNormalizedBounds(x: 0.2, y: 0.25, width: 0.4, height: 0.5)
            )
        ])
        let pipeline = VisionOCRPipeline(recognizer: recognizer)
        let input = OCRFrameInput(
            image: try fixtureImage(),
            orientation: .right,
            sourcePixelWidth: 1_000,
            sourcePixelHeight: 800,
            processedRegion: OCRPixelRect(x: 100, y: 200, width: 500, height: 400)
        )

        let spans = try await pipeline.recognize(
            input,
            frameID: frameID,
            idProvider: { deterministicUUID($0) }
        )

        let observedOrientations = await recognizer.observedOrientations
        XCTAssertEqual(observedOrientations, [.right])
        let span = try XCTUnwrap(spans.first)
        let bounds = try XCTUnwrap(span.bounds)
        let confidence = try XCTUnwrap(span.confidence)
        XCTAssertEqual(span.text, "Café plan")
        XCTAssertEqual(span.source, .visionOCR)
        XCTAssertEqual(confidence, Float(0.94), accuracy: Float(0.000_1))
        XCTAssertEqual(span.languageCode, "fr")
        XCTAssertEqual(bounds.x, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(bounds.y, 0.375, accuracy: 0.000_001)
        XCTAssertEqual(bounds.width, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(bounds.height, 0.25, accuracy: 0.000_001)
    }

    func testThermalPressureDefersWithoutLeasingOrRecognizing() async throws {
        let store = FixtureOCRLeaseStore()
        let recognizer = FixtureVisionRecognizer(observations: [])
        let worker = VisionOCRWorker(
            pipeline: VisionOCRPipeline(recognizer: recognizer),
            leaseStore: store
        )
        let outcome = await worker.run(
            job: fixtureJob(attempt: 0),
            input: try fixtureInput(),
            thermalState: .serious,
            now: Date(timeIntervalSince1970: 1_777_777_700)
        )

        XCTAssertEqual(outcome, .deferred(.thermalPressure))
        let events = await store.events
        let callCount = await recognizer.callCount
        XCTAssertEqual(events, [])
        XCTAssertEqual(callCount, 0)
    }

    func testActorAllowsOnlyOneOCRLeaseAndCancellationPublishesNoSpans() async throws {
        let store = FixtureOCRLeaseStore()
        let recognizer = FixtureVisionRecognizer(
            observations: [OCRRawObservation.fixture()],
            gate: AsyncGate()
        )
        let worker = VisionOCRWorker(
            pipeline: VisionOCRPipeline(recognizer: recognizer),
            leaseStore: store
        )
        let job = fixtureJob(attempt: 0)
        let input = try fixtureInput()

        let first = Task {
            await worker.run(job: job, input: input, thermalState: .nominal, now: .now)
        }
        await recognizer.waitUntilStarted()
        let second = await worker.run(
            job: fixtureJob(idOffset: 1, attempt: 0),
            input: input,
            thermalState: .nominal,
            now: .now
        )
        first.cancel()
        await recognizer.release()
        let cancelled = await first.value

        XCTAssertEqual(second, .deferred(.workerBusy))
        XCTAssertEqual(cancelled, .cancelled)
        let maximumConcurrentCalls = await recognizer.maximumConcurrentCalls
        let events = await store.events
        XCTAssertEqual(maximumConcurrentCalls, 1)
        XCTAssertEqual(events.filter { $0 == "publish" }.count, 0)
        XCTAssertTrue(events.contains("cancel"))
    }

    func testFailureIsRetryableBeforeThirdAttemptAndPermanentAtLimit() async throws {
        for (attempt, expected) in [
            (1, OCRJobExecutionOutcome.retryableFailure("vision_failed")),
            (2, OCRJobExecutionOutcome.permanentFailure("vision_failed")),
        ] {
            let store = FixtureOCRLeaseStore()
            let worker = VisionOCRWorker(
                pipeline: VisionOCRPipeline(
                    recognizer: FixtureVisionRecognizer(error: FixtureError.failed)
                ),
                leaseStore: store
            )
            let outcome = await worker.run(
                job: fixtureJob(attempt: attempt),
                input: try fixtureInput(),
                thermalState: .fair,
                now: .now
            )
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(
                outcome.visibleStatus,
                attempt == 1
                    ? "Text recognition will retry."
                    : "Text recognition failed. The capture remains available without OCR text."
            )
            let events = await store.events
            XCTAssertTrue(events.contains(attempt == 1 ? "retry" : "permanent"))
        }
    }

    func testLM006CanonicalFullVisionCorpusRemainsPinnedAtPerfectRecall() throws {
        let reportURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Results/LM-006/report.json")
        let report =
            try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any]
        let results = try XCTUnwrap(report?["results"] as? [String: Any])
        XCTAssertEqual(results["ocrFixtureCount"] as? Int, 200)
        XCTAssertEqual(results["highContrastLatinRecall"] as? Double, 1.0)
        XCTAssertEqual(results["fullOCRRecall"] as? Double, 1.0)
    }

    private let frameID = UUID(uuidString: "31000000-0000-0000-0000-000000000031")!

    private func fixtureJob(idOffset: Int = 0, attempt: Int) -> OCRJobLeaseRequest {
        OCRJobLeaseRequest(
            jobID: deterministicUUID(100 + idOffset),
            frameID: frameID,
            attemptCount: attempt
        )
    }

    private func fixtureInput() throws -> OCRFrameInput {
        OCRFrameInput(
            image: try fixtureImage(),
            orientation: .up,
            sourcePixelWidth: 20,
            sourcePixelHeight: 20,
            processedRegion: OCRPixelRect(x: 0, y: 0, width: 20, height: 20)
        )
    }

    private func fixtureImage() throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 20,
                height: 20,
                bitsPerComponent: 8,
                bytesPerRow: 80,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try XCTUnwrap(context.makeImage())
    }

    private func deterministicUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "31000000-0000-0000-0000-%012d", index + 1))!
    }
}

private enum FixtureError: Error { case failed }

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FixtureVisionRecognizer: VisionTextRecognizing {
    private let observations: [OCRRawObservation]
    private let error: Error?
    private let gate: AsyncGate?
    private(set) var observedOrientations: [OCRImageOrientation] = []
    private(set) var callCount = 0
    private(set) var maximumConcurrentCalls = 0
    private var concurrentCalls = 0

    init(
        observations: [OCRRawObservation] = [],
        error: Error? = nil,
        gate: AsyncGate? = nil
    ) {
        self.observations = observations
        self.error = error
        self.gate = gate
    }

    func recognize(_ input: OCRFrameInput) async throws -> [OCRRawObservation] {
        callCount += 1
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
        observedOrientations.append(input.orientation)
        defer { concurrentCalls -= 1 }
        if let gate { await gate.wait() }
        if let error { throw error }
        return observations
    }

    func waitUntilStarted() async {
        while callCount == 0 { await Task.yield() }
    }

    func release() async {
        if let gate { await gate.open() }
    }
}

private actor FixtureOCRLeaseStore: OCRJobLeasePersisting {
    private(set) var events: [String] = []

    func begin(_ lease: OCRJobLease, now: Date) async -> Bool {
        events.append("begin")
        return true
    }

    func publish(_ lease: OCRJobLease, spans: [TextSpan]) async throws {
        events.append("publish")
    }

    func cancel(_ lease: OCRJobLease) async { events.append("cancel") }
    func retry(_ lease: OCRJobLease, errorCode: String) async { events.append("retry") }
    func failPermanently(_ lease: OCRJobLease, errorCode: String) async {
        events.append("permanent")
    }
}

extension OCRRawObservation {
    fileprivate static func fixture() -> Self {
        Self(
            text: "Fixture",
            confidence: 0.99,
            languageCode: "en",
            visionBounds: OCRNormalizedBounds(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        )
    }
}
