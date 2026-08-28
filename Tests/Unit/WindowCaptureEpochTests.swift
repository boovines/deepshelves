import CoreVideo
import Foundation
import MemoryCapture
import XCTest

final class WindowCaptureEpochTests: XCTestCase {
    func testEpochBeginsOnlyAfterSuccessfulSingleWindowFilterApplication() async throws {
        let fixture = try loadFixture()
        let clock = FakeEpochClock(nowNanoseconds: 10_000)
        let updater = ControllableSingleWindowFilterUpdater(clock: clock)
        let manager = WindowCaptureEpochManager(
            filterUpdater: updater,
            clock: clock,
            idGenerator: DeterministicEpochIDGenerator(startingAt: 24)
        )
        let request = approvedRequest(index: 1)

        let transition = Task {
            try await manager.transition(to: request, startedNanoseconds: 10_000)
        }
        await updater.waitForPendingCount(1)
        let beforeApplication = await manager.currentEpoch()
        XCTAssertNil(beforeApplication)
        clock.advance(by: 25_000_000)
        await updater.completeNext()

        let transitionValue = try await transition.value
        let epoch = try XCTUnwrap(transitionValue)
        XCTAssertEqual(epoch.targetWindowID, request.target.windowID)
        XCTAssertEqual(epoch.processID, request.target.processID)
        XCTAssertEqual(epoch.policyDecisionID, request.policyDecisionID)
        XCTAssertEqual(epoch.filterGeneration, 1)
        XCTAssertEqual(epoch.filterAppliedNanoseconds, clock.nowNanoseconds())
        let activeEpoch = await manager.currentEpoch()
        let appliedWindowIDs = await updater.appliedWindowIDs()
        let latencyP95 = await manager.transitionLatencyP95Nanoseconds()
        XCTAssertEqual(activeEpoch, epoch)
        XCTAssertEqual(appliedWindowIDs, [request.target.windowID])
        XCTAssertLessThan(
            try XCTUnwrap(latencyP95),
            fixture.maximumTransitionLatencyNanoseconds
        )
    }

    func testFailedFilterApplicationLeavesNoActiveEpoch() async throws {
        let clock = FakeEpochClock(nowNanoseconds: 20_000)
        let updater = ControllableSingleWindowFilterUpdater(clock: clock)
        let manager = WindowCaptureEpochManager(filterUpdater: updater, clock: clock)
        let request = approvedRequest(index: 2)

        let transition = Task {
            try await manager.transition(to: request, startedNanoseconds: 20_000)
        }
        await updater.waitForPendingCount(1)
        await updater.failNext()
        do {
            _ = try await transition.value
            XCTFail("Expected the filter update to fail")
        } catch {
            XCTAssertEqual(error as? EpochFixtureError, .filterFailure)
        }
        let activeEpoch = await manager.currentEpoch()
        XCTAssertNil(activeEpoch)
    }

    func testSupersededFilterCompletionCannotInstallPriorEpoch() async throws {
        let clock = FakeEpochClock(nowNanoseconds: 30_000)
        let updater = ControllableSingleWindowFilterUpdater(clock: clock)
        let manager = WindowCaptureEpochManager(
            filterUpdater: updater,
            clock: clock,
            idGenerator: DeterministicEpochIDGenerator(startingAt: 100)
        )
        let priorRequest = approvedRequest(index: 3)
        let currentRequest = approvedRequest(index: 4)

        let prior = Task {
            try await manager.transition(to: priorRequest, startedNanoseconds: 30_000)
        }
        await updater.waitForPendingCount(1)
        let current = Task {
            try await manager.transition(to: currentRequest, startedNanoseconds: 31_000)
        }
        await Task.yield()
        clock.advance(by: 10_000_000)
        await updater.completeNext()
        let priorValue = try await prior.value
        XCTAssertNil(priorValue)
        await updater.waitForPendingCount(1)
        let epochBeforeCurrentApplication = await manager.currentEpoch()
        XCTAssertNil(epochBeforeCurrentApplication)
        clock.advance(by: 10_000_000)
        await updater.completeNext()

        let currentValue = try await current.value
        let installed = try XCTUnwrap(currentValue)
        let activeEpoch = await manager.currentEpoch()
        let appliedWindowIDs = await updater.appliedWindowIDs()
        XCTAssertEqual(installed.targetWindowID, currentRequest.target.windowID)
        XCTAssertEqual(activeEpoch, installed)
        XCTAssertEqual(
            appliedWindowIDs,
            [priorRequest.target.windowID, currentRequest.target.windowID]
        )
    }

    func testAdmissionRejectsPriorFilterTargetURLResizeAndRevokedEpochRaces() async throws {
        let fixture = try loadFixture()
        let epochID = deterministicUUID(500)
        let policyID = deterministicUUID(600)
        let epoch = WindowCaptureEpoch(
            id: epochID,
            targetWindowID: 8,
            processID: 42,
            bundleIdentifier: "com.example.fixture",
            approvedBounds: PointRect(x: 10, y: 10, width: 1_200, height: 800),
            policyDecisionID: policyID,
            encodedSize: PixelSize(width: 1_200, height: 800),
            filterGeneration: 50,
            filterAppliedNanoseconds: 1_000
        )
        let current = FrameCandidate(
            epochID: epochID,
            targetWindowID: 8,
            focusedWindowID: 8,
            dimensions: epoch.encodedSize,
            deliveredNanoseconds: 1_001,
            policyApproved: true,
            filterGeneration: 50,
            policyDecisionID: policyID
        )

        for index in 0..<fixture.rapidRaceCount {
            let staleGeneration = UInt64(index)
            XCTAssertEqual(
                FrameAdmission.evaluate(
                    current.with(filterGeneration: staleGeneration),
                    against: epoch
                ),
                .rejected(.filterGenerationMismatch)
            )
        }
        XCTAssertEqual(
            FrameAdmission.evaluate(current.with(targetWindowID: 7), against: epoch),
            .rejected(.targetMismatch)
        )
        XCTAssertEqual(
            FrameAdmission.evaluate(
                current.with(policyDecisionID: deterministicUUID(601)),
                against: epoch
            ),
            .rejected(.policyDecisionMismatch)
        )
        XCTAssertEqual(
            FrameAdmission.evaluate(
                current.with(dimensions: PixelSize(width: 1_000, height: 700)),
                against: epoch
            ),
            .rejected(.dimensionMismatch)
        )
        XCTAssertEqual(
            FrameAdmission.evaluate(current, against: epoch, epochIsActive: false),
            .rejected(.epochRevoked)
        )
        XCTAssertEqual(FrameAdmission.evaluate(current, against: epoch), .accepted)
    }

    func testFinalAdmissionRepeatsPolicyAndEpochContextImmediatelyBeforeAppend() async throws {
        let policy = PrivacyPolicy(
            configuration: .personalDefault(selfBundleIdentifier: "com.example.deepshelves")
        )
        let epochID = deterministicUUID(650)
        var context = PrivacyEvaluationContext(
            targetWindowID: 8,
            processID: 42,
            bundleIdentifier: "com.example.fixture",
            targetIsUniquelyResolved: true,
            recordingIsActive: true,
            screenIsLocked: false,
            secureInputIsActive: false,
            browserContext: nil,
            captureEpochID: epochID
        )
        let prefilter = await policy.prefilter(context: context)
        guard case .allowed(let approval) = prefilter else {
            return XCTFail("Expected prefilter approval")
        }
        let epoch = WindowCaptureEpoch(
            id: epochID,
            targetWindowID: 8,
            processID: 42,
            bundleIdentifier: "com.example.fixture",
            approvedBounds: PointRect(x: 0, y: 0, width: 1_200, height: 800),
            policyDecisionID: approval.decision.audit.id,
            encodedSize: PixelSize(width: 1_200, height: 800),
            filterGeneration: 12,
            filterAppliedNanoseconds: 1_000
        )
        let candidate = FrameCandidate(
            epochID: epoch.id,
            targetWindowID: epoch.targetWindowID,
            focusedWindowID: epoch.targetWindowID,
            dimensions: epoch.encodedSize,
            deliveredNanoseconds: 1_001,
            policyApproved: false,
            filterGeneration: epoch.filterGeneration,
            policyDecisionID: epoch.policyDecisionID
        )
        let gate = FinalEpochFrameAdmissionGate(privacyPolicy: policy)
        let allowed = await gate.evaluate(
            candidate,
            against: epoch,
            approval: approval,
            currentContext: context
        )
        XCTAssertEqual(allowed.admission, .accepted)
        XCTAssertTrue(allowed.policyDecision.isAllowed)

        context.captureEpochID = deterministicUUID(651)
        let stale = await gate.evaluate(
            candidate,
            against: epoch,
            approval: approval,
            currentContext: context
        )
        XCTAssertEqual(stale.admission, .rejected(.policyDenied))
        XCTAssertEqual(stale.policyDecision.reason, .staleTargetOrContext)
    }

    func testMeasuredLuminanceDedupSeparatesFiftyNearDuplicatesFromChanges() throws {
        let fixture = try loadFixture()
        let baseline = try LuminanceSignature(samples: Array(repeating: 100, count: 64 * 64))
        var nearDuplicateCount = 0
        var visualChangeCount = 0

        for index in 0..<fixture.nearDuplicateSequenceCount {
            var near = Array(repeating: UInt8(100), count: 64 * 64)
            for sampleIndex in stride(from: index, to: near.count, by: 50) {
                near[sampleIndex] = UInt8(99 + (index % 3))
            }
            let nearSignature = try LuminanceSignature(samples: near)
            if !nearSignature.isVisualChange(
                from: baseline,
                threshold: fixture.visualDifferenceThreshold
            ) {
                nearDuplicateCount += 1
            }

            var changed = near
            for sampleIndex in 0..<1_024 {
                changed[(sampleIndex + index * 17) % changed.count] = 132
            }
            let changedSignature = try LuminanceSignature(samples: changed)
            if changedSignature.isVisualChange(
                from: baseline,
                threshold: fixture.visualDifferenceThreshold
            ) {
                visualChangeCount += 1
            }
        }

        XCTAssertEqual(nearDuplicateCount, fixture.nearDuplicateSequenceCount)
        XCTAssertEqual(visualChangeCount, fixture.nearDuplicateSequenceCount)
        XCTAssertEqual(
            baseline.samples.count, fixture.luminanceGridWidth * fixture.luminanceGridHeight)
    }

    func testMeasuredAcceptanceCadenceIndexesAtTwoSecondsAndHeartbeatsAtThirty() throws {
        let epochID = deterministicUUID(700)
        let baseline = try LuminanceSignature(samples: Array(repeating: 90, count: 64 * 64))
        let changed = try LuminanceSignature(samples: Array(repeating: 110, count: 64 * 64))
        var gate = MeasuredFrameAcceptanceGate(visualDifferenceThreshold: 2)

        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID,
                timestampNanoseconds: 0,
                signature: baseline,
                lastActivityNanoseconds: 0
            ).decision,
            .accepted(index: true, reason: .firstEpochFrame)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID,
                timestampNanoseconds: 500_000_000,
                signature: changed,
                lastActivityNanoseconds: 0
            ).decision,
            .rejected(.activeRateLimit)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID,
                timestampNanoseconds: 1_000_000_000,
                signature: changed,
                lastActivityNanoseconds: 0
            ).decision,
            .accepted(index: false, reason: .visualChange)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID,
                timestampNanoseconds: 2_000_000_000,
                signature: changed,
                lastActivityNanoseconds: 0
            ).decision,
            .rejected(.staticDuplicate)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID,
                timestampNanoseconds: 31_000_000_000,
                signature: changed,
                lastActivityNanoseconds: 31_000_000_000
            ).decision,
            .accepted(index: true, reason: .staticHeartbeat)
        )
    }

    func testBackpressureIsBoundedKeepsNewestAndDropsHeartbeatsBeforeVisualChanges() throws {
        let fixture = try loadFixture()
        let epochID = deterministicUUID(800)
        var queue = NewestFrameBackpressureQueue<String>(capacity: fixture.mediaQueueCapacity)
        queue.activate(epochID: epochID)
        _ = queue.enqueue(frame(id: 1, epochID: epochID, reason: .visualChange))
        _ = queue.enqueue(frame(id: 2, epochID: epochID, reason: .staticHeartbeat))
        _ = queue.enqueue(frame(id: 3, epochID: epochID, reason: .visualChange))
        _ = queue.enqueue(frame(id: 4, epochID: epochID, reason: .staticHeartbeat))

        let firstOverload = queue.enqueue(
            frame(id: 5, epochID: epochID, reason: .visualChange)
        )
        XCTAssertEqual(firstOverload.dropped.map(\.frame.payload), ["frame-2"])
        XCTAssertEqual(firstOverload.dropped.map(\.reason), [.redundantHeartbeat])
        XCTAssertEqual(queue.count, fixture.mediaQueueCapacity)
        XCTAssertEqual(queue.frames.map(\.payload), ["frame-1", "frame-3", "frame-4", "frame-5"])

        let secondOverload = queue.enqueue(
            frame(id: 6, epochID: epochID, reason: .visualChange)
        )
        XCTAssertEqual(secondOverload.dropped.map(\.frame.payload), ["frame-4"])
        XCTAssertEqual(queue.frames.map(\.payload), ["frame-1", "frame-3", "frame-5", "frame-6"])
        XCTAssertEqual(queue.peakCount, fixture.mediaQueueCapacity)
    }

    func testEpochActivationFlushesEveryPriorCandidateBeforeNewFrames() throws {
        let priorEpochID = deterministicUUID(900)
        let currentEpochID = deterministicUUID(901)
        var queue = NewestFrameBackpressureQueue<String>(capacity: 4)
        queue.activate(epochID: priorEpochID)
        _ = queue.enqueue(frame(id: 1, epochID: priorEpochID, reason: .visualChange))
        _ = queue.enqueue(frame(id: 2, epochID: priorEpochID, reason: .staticHeartbeat))

        let flushed = queue.activate(epochID: currentEpochID)
        XCTAssertEqual(flushed.map(\.frame.payload), ["frame-1", "frame-2"])
        XCTAssertEqual(flushed.map(\.reason), [.staleEpoch, .staleEpoch])
        XCTAssertTrue(queue.frames.isEmpty)
        let staleArrival = queue.enqueue(
            frame(id: 3, epochID: priorEpochID, reason: .visualChange)
        )
        XCTAssertFalse(staleArrival.accepted)
        XCTAssertEqual(staleArrival.dropped.map(\.reason), [.staleEpoch])
        _ = queue.enqueue(frame(id: 4, epochID: currentEpochID, reason: .firstEpochFrame))
        XCTAssertEqual(queue.frames.map(\.payload), ["frame-4"])

        let revoked = queue.revoke()
        XCTAssertEqual(revoked.map(\.reason), [.revoked])
        XCTAssertNil(queue.activeEpochID)
    }

    func testShippingEpochStreamUsesOnlySingleWindowFiltersAndTagsOutputGeneration() throws {
        var rawBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_32BGRA,
                nil,
                &rawBuffer
            ),
            kCVReturnSuccess
        )
        let lease = ForegroundWindowPixelBuffer(
            pixelBuffer: try XCTUnwrap(rawBuffer),
            targetWindowID: 42,
            capturedNanoseconds: 1_000,
            filterGeneration: 77
        )
        XCTAssertEqual(lease.filterGeneration, 77)
        lease.discardWithoutPersistence()

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(
                path: "Packages/MemoryCapture/Sources/MemoryCapture/EpochCapturePipeline.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("ScreenCaptureKitEpochStream"))
        XCTAssertTrue(source.contains("updateContentFilter"))
        XCTAssertTrue(source.contains("SCContentFilter(desktopIndependentWindow:"))
        XCTAssertFalse(source.contains("SCContentFilter(display:"))
        XCTAssertFalse(source.contains("excludingWindows:"))
        XCTAssertFalse(source.contains("includingApplications:"))
    }

    private func frame(
        id: Int,
        epochID: UUID,
        reason: FrameAcceptanceReason
    ) -> QueuedCaptureFrame<String> {
        QueuedCaptureFrame(
            id: deterministicUUID(1_000 + id),
            epochID: epochID,
            targetWindowID: UInt32(id),
            deliveredNanoseconds: UInt64(id),
            reason: reason,
            shouldIndex: reason == .firstEpochFrame,
            payload: "frame-\(id)"
        )
    }

    private func approvedRequest(index: Int) -> ApprovedWindowCaptureRequest {
        ApprovedWindowCaptureRequest(
            target: .fixture(
                windowID: UInt32(10_000 + index),
                processID: Int32(1_000 + index),
                displayID: 1,
                width: 1_200 + index * 2,
                height: 800 + index * 2
            ),
            bundleIdentifier: "com.example.fixture.\(index)",
            approvedBounds: PointRect(
                x: Double(index),
                y: Double(index),
                width: Double(1_200 + index * 2),
                height: Double(800 + index * 2)
            ),
            policyDecisionID: deterministicUUID(2_000 + index)
        )
    }

    private func loadFixture() throws -> LM024Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM024/epoch-race-and-dedup.json")
        return try JSONDecoder().decode(LM024Fixture.self, from: Data(contentsOf: url))
    }
}

private struct LM024Fixture: Decodable {
    let seed: UInt64
    let rapidRaceCount: Int
    let nearDuplicateSequenceCount: Int
    let luminanceGridWidth: Int
    let luminanceGridHeight: Int
    let visualDifferenceThreshold: Double
    let mediaQueueCapacity: Int
    let maximumTransitionLatencyNanoseconds: UInt64
}

private enum EpochFixtureError: Error, Equatable {
    case filterFailure
}

private final class FakeEpochClock: ActivityMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(nowNanoseconds: UInt64) {
        value = nowNanoseconds
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock { value }
    }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }
}

private final class DeterministicEpochIDGenerator: EpochIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: Int

    init(startingAt: Int) {
        nextValue = startingAt
    }

    func nextID() -> UUID {
        lock.withLock {
            defer { nextValue += 1 }
            return deterministicUUID(nextValue)
        }
    }
}

private actor ControllableSingleWindowFilterUpdater: SingleWindowFilterUpdating {
    private struct Pending {
        let target: ForegroundWindowCaptureTarget
        let generation: UInt64
        let continuation: CheckedContinuation<SingleWindowFilterReceipt, Error>
    }

    private let clock: FakeEpochClock
    private var pending: [Pending] = []
    private var applied: [UInt32] = []

    init(clock: FakeEpochClock) {
        self.clock = clock
    }

    func apply(
        target: ForegroundWindowCaptureTarget,
        generation: UInt64,
        dimensions: PixelSize
    ) async throws -> SingleWindowFilterReceipt {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(
                Pending(target: target, generation: generation, continuation: continuation)
            )
        }
    }

    func stop() async {}

    func waitForPendingCount(_ expected: Int) async {
        while pending.count < expected {
            await Task.yield()
        }
    }

    func completeNext() {
        let next = pending.removeFirst()
        applied.append(next.target.windowID)
        next.continuation.resume(
            returning: SingleWindowFilterReceipt(
                generation: next.generation,
                targetWindowID: next.target.windowID,
                dimensions: CaptureGeometry.encodedSize(for: next.target.bounds),
                appliedNanoseconds: clock.nowNanoseconds()
            )
        )
    }

    func failNext() {
        pending.removeFirst().continuation.resume(throwing: EpochFixtureError.filterFailure)
    }

    func appliedWindowIDs() -> [UInt32] {
        applied
    }
}

extension FrameCandidate {
    fileprivate func with(
        targetWindowID: UInt32? = nil,
        dimensions: PixelSize? = nil,
        filterGeneration: UInt64? = nil,
        policyDecisionID: UUID? = nil
    ) -> FrameCandidate {
        FrameCandidate(
            epochID: epochID,
            targetWindowID: targetWindowID ?? self.targetWindowID,
            focusedWindowID: focusedWindowID,
            dimensions: dimensions ?? self.dimensions,
            deliveredNanoseconds: deliveredNanoseconds,
            policyApproved: policyApproved,
            filterGeneration: filterGeneration ?? self.filterGeneration,
            policyDecisionID: policyDecisionID ?? self.policyDecisionID
        )
    }
}

private func deterministicUUID(_ value: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", value))")!
}
