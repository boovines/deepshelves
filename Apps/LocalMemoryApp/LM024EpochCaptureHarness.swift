import Foundation
import MemoryCapture

private struct LM024RaceRecord: Codable {
    let id: String
    let category: String
    let targetWindowID: UInt32
    let filterGeneration: UInt64
    let transitionLatencyNanoseconds: UInt64
    let staleRejection: String
    let currentAccepted: Bool
}

private struct LM024EpochCaptureReport: Codable {
    let schemaVersion: Int
    let seed: UInt64
    let rapidRaceCount: Int
    let exactRaceCount: Int
    let raceCategoryCounts: [String: Int]
    let staleFrameAcceptedCount: Int
    let currentFrameAcceptedCount: Int
    let epochCount: Int
    let filterApplicationCount: Int
    let transitionLatencyP95Nanoseconds: UInt64
    let transitionsWithinOneSecondCount: Int
    let nearDuplicateSequenceCount: Int
    let nearDuplicateDeduplicatedCount: Int
    let visualChangeAcceptedCount: Int
    let luminanceGridSampleCount: Int
    let visualDifferenceThreshold: Double
    let mediaQueueCapacity: Int
    let mediaQueuePeakCount: Int
    let staleQueueDropCount: Int
    let heartbeatQueueDropCount: Int
    let oldestQueueDropCount: Int
    let newestFrameRetained: Bool
    let singleWindowFilterOnly: Bool
    let records: [LM024RaceRecord]
    let allInvariantsPassed: Bool
}

private final class LM024EpochClock: ActivityMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock { value }
    }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }
}

private final class LM024EpochIDGenerator: EpochIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 24_000

    func nextID() -> UUID {
        lock.withLock {
            defer { value += 1 }
            return LM024EpochCaptureHarness.uuid(value)
        }
    }
}

private actor LM024FilterUpdater: SingleWindowFilterUpdating {
    private let clock: LM024EpochClock
    private var applications: [UInt32] = []
    private var latencies: [UInt64] = []

    init(clock: LM024EpochClock) {
        self.clock = clock
    }

    func apply(
        target: ForegroundWindowCaptureTarget,
        generation: UInt64,
        dimensions: PixelSize
    ) -> SingleWindowFilterReceipt {
        let latency = UInt64(10_000_000 + applications.count * 1_000_000)
        clock.advance(by: latency)
        applications.append(target.windowID)
        latencies.append(latency)
        return SingleWindowFilterReceipt(
            generation: generation,
            targetWindowID: target.windowID,
            dimensions: dimensions,
            appliedNanoseconds: clock.nowNanoseconds()
        )
    }

    func stop() {}

    func snapshot() -> (applications: [UInt32], latencies: [UInt64]) {
        (applications, latencies)
    }
}

private final class LM024BlockingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func set(_ result: Result<Data, Error>) {
        lock.withLock { self.result = result }
    }

    func get() -> Result<Data, Error> {
        lock.withLock { result! }
    }
}

enum LM024EpochCaptureHarness {
    private static let seed: UInt64 = 1_279_938_624
    private static let raceCount = 50
    private static let differenceThreshold = 2.0

    static func runBlocking() throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let output = LM024BlockingResult()
        Task.detached {
            do {
                output.set(.success(try await run()))
            } catch {
                output.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try output.get().get()
    }

    fileprivate static func uuid(_ value: Int) -> UUID {
        UUID(
            uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", value))"
        )!
    }

    private static func run() async throws -> Data {
        let clock = LM024EpochClock(1_000_000_000)
        let updater = LM024FilterUpdater(clock: clock)
        let manager = WindowCaptureEpochManager(
            filterUpdater: updater,
            clock: clock,
            idGenerator: LM024EpochIDGenerator()
        )
        let categories = ["focus", "filter", "url", "resize"]
        var categoryCounts: [String: Int] = [:]
        var records: [LM024RaceRecord] = []
        var staleFrameAcceptedCount = 0
        var currentFrameAcceptedCount = 0
        var epochIDs: Set<UUID> = []
        var priorTargetWindowID: UInt32 = 50_000
        var priorPolicyDecisionID = uuid(60_000)
        var priorDimensions = PixelSize(width: 1_200, height: 800)

        for index in 0..<raceCount {
            let category = categories[index % categories.count]
            categoryCounts[category, default: 0] += 1
            let targetWindowID: UInt32
            if category == "focus" || category == "filter" {
                targetWindowID = UInt32(50_001 + index)
            } else {
                targetWindowID = priorTargetWindowID
            }
            let width = category == "resize" ? 1_200 + (index + 1) * 2 : 1_200
            let height = category == "resize" ? 800 + (index + 1) * 2 : 800
            let target = ForegroundWindowCaptureTarget.fixture(
                windowID: targetWindowID,
                processID: Int32(4_000 + index),
                displayID: 1,
                width: width,
                height: height
            )
            let policyDecisionID = category == "url" ? uuid(60_001 + index) : uuid(70_000 + index)
            let request = ApprovedWindowCaptureRequest(
                target: target,
                bundleIdentifier: "com.example.lm024.\(index)",
                approvedBounds: target.bounds,
                policyDecisionID: policyDecisionID
            )
            let started = clock.nowNanoseconds()
            guard
                let epoch = try await manager.transition(
                    to: request,
                    startedNanoseconds: started
                )
            else {
                continue
            }
            epochIDs.insert(epoch.id)
            let staleCandidate: FrameCandidate
            switch category {
            case "focus":
                staleCandidate = candidate(
                    epoch: epoch,
                    targetWindowID: priorTargetWindowID
                )
            case "url":
                staleCandidate = candidate(
                    epoch: epoch,
                    policyDecisionID: priorPolicyDecisionID
                )
            case "resize":
                staleCandidate = candidate(epoch: epoch, dimensions: priorDimensions)
            default:
                staleCandidate = candidate(
                    epoch: epoch,
                    filterGeneration: epoch.filterGeneration - 1
                )
            }
            let staleDecision = FrameAdmission.evaluate(staleCandidate, against: epoch)
            if staleDecision == .accepted {
                staleFrameAcceptedCount += 1
            }
            let currentDecision = FrameAdmission.evaluate(candidate(epoch: epoch), against: epoch)
            if currentDecision == .accepted {
                currentFrameAcceptedCount += 1
            }
            let applied = await updater.snapshot().latencies.last ?? 0
            records.append(
                LM024RaceRecord(
                    id: "race-\(String(format: "%03d", index))",
                    category: category,
                    targetWindowID: epoch.targetWindowID,
                    filterGeneration: epoch.filterGeneration,
                    transitionLatencyNanoseconds: applied,
                    staleRejection: rejectionName(staleDecision),
                    currentAccepted: currentDecision == .accepted
                )
            )
            priorTargetWindowID = epoch.targetWindowID
            priorPolicyDecisionID = policyDecisionID
            priorDimensions = epoch.encodedSize
        }

        let baseline = try LuminanceSignature(
            samples: Array(repeating: 100, count: LuminanceSignature.sampleCount)
        )
        var nearDuplicateDeduplicatedCount = 0
        var visualChangeAcceptedCount = 0
        for index in 0..<raceCount {
            var near = Array(repeating: UInt8(100), count: LuminanceSignature.sampleCount)
            for sampleIndex in stride(from: index, to: near.count, by: raceCount) {
                near[sampleIndex] = UInt8(99 + index % 3)
            }
            let nearSignature = try LuminanceSignature(samples: near)
            if !nearSignature.isVisualChange(from: baseline, threshold: differenceThreshold) {
                nearDuplicateDeduplicatedCount += 1
            }
            var changed = near
            for sampleIndex in 0..<1_024 {
                changed[(sampleIndex + index * 17) % changed.count] = 132
            }
            let changedSignature = try LuminanceSignature(samples: changed)
            if changedSignature.isVisualChange(from: baseline, threshold: differenceThreshold) {
                visualChangeAcceptedCount += 1
            }
        }

        let queueEpoch = uuid(80_000)
        let staleQueueEpoch = uuid(79_999)
        var queue = NewestFrameBackpressureQueue<String>(capacity: 4)
        queue.activate(epochID: staleQueueEpoch)
        _ = queue.enqueue(queueFrame(index: 0, epochID: staleQueueEpoch, reason: .visualChange))
        let activationDrops = queue.activate(epochID: queueEpoch)
        var staleQueueDropCount = activationDrops.filter { $0.reason == .staleEpoch }.count
        let staleArrival = queue.enqueue(
            queueFrame(index: 1, epochID: staleQueueEpoch, reason: .visualChange)
        )
        staleQueueDropCount += staleArrival.dropped.filter { $0.reason == .staleEpoch }.count
        var heartbeatQueueDropCount = 0
        var oldestQueueDropCount = 0
        for index in 2..<102 {
            let reason: FrameAcceptanceReason =
                index.isMultiple(of: 3)
                ? .staticHeartbeat
                : .visualChange
            let result = queue.enqueue(
                queueFrame(index: index, epochID: queueEpoch, reason: reason))
            heartbeatQueueDropCount +=
                result.dropped.filter {
                    $0.reason == .redundantHeartbeat
                }.count
            oldestQueueDropCount += result.dropped.filter { $0.reason == .oldestCandidate }.count
        }
        let newestFrameRetained = queue.frames.last?.payload == "frame-101"
        let updaterSnapshot = await updater.snapshot()
        let transitionP95 = await manager.transitionLatencyP95Nanoseconds() ?? UInt64.max
        let transitionsWithinOneSecondCount = updaterSnapshot.latencies.filter {
            $0 < 1_000_000_000
        }.count
        let exactRaceCount = records.filter {
            $0.currentAccepted && $0.staleRejection != "accepted"
        }.count
        let allInvariantsPassed =
            records.count == raceCount
            && exactRaceCount == raceCount
            && staleFrameAcceptedCount == 0
            && currentFrameAcceptedCount == raceCount
            && epochIDs.count == raceCount
            && updaterSnapshot.applications.count == raceCount
            && transitionP95 < 1_000_000_000
            && transitionsWithinOneSecondCount == raceCount
            && nearDuplicateDeduplicatedCount == raceCount
            && visualChangeAcceptedCount == raceCount
            && queue.peakCount == 4
            && queue.count == 4
            && staleQueueDropCount == 2
            && heartbeatQueueDropCount > 0
            && oldestQueueDropCount > 0
            && newestFrameRetained

        let report = LM024EpochCaptureReport(
            schemaVersion: 1,
            seed: seed,
            rapidRaceCount: raceCount,
            exactRaceCount: exactRaceCount,
            raceCategoryCounts: categoryCounts,
            staleFrameAcceptedCount: staleFrameAcceptedCount,
            currentFrameAcceptedCount: currentFrameAcceptedCount,
            epochCount: epochIDs.count,
            filterApplicationCount: updaterSnapshot.applications.count,
            transitionLatencyP95Nanoseconds: transitionP95,
            transitionsWithinOneSecondCount: transitionsWithinOneSecondCount,
            nearDuplicateSequenceCount: raceCount,
            nearDuplicateDeduplicatedCount: nearDuplicateDeduplicatedCount,
            visualChangeAcceptedCount: visualChangeAcceptedCount,
            luminanceGridSampleCount: LuminanceSignature.sampleCount,
            visualDifferenceThreshold: differenceThreshold,
            mediaQueueCapacity: queue.capacity,
            mediaQueuePeakCount: queue.peakCount,
            staleQueueDropCount: staleQueueDropCount,
            heartbeatQueueDropCount: heartbeatQueueDropCount,
            oldestQueueDropCount: oldestQueueDropCount,
            newestFrameRetained: newestFrameRetained,
            singleWindowFilterOnly: true,
            records: records,
            allInvariantsPassed: allInvariantsPassed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    private static func candidate(
        epoch: WindowCaptureEpoch,
        targetWindowID: UInt32? = nil,
        dimensions: PixelSize? = nil,
        filterGeneration: UInt64? = nil,
        policyDecisionID: UUID? = nil
    ) -> FrameCandidate {
        FrameCandidate(
            epochID: epoch.id,
            targetWindowID: targetWindowID ?? epoch.targetWindowID,
            focusedWindowID: epoch.targetWindowID,
            dimensions: dimensions ?? epoch.encodedSize,
            deliveredNanoseconds: epoch.filterAppliedNanoseconds + 1,
            policyApproved: true,
            filterGeneration: filterGeneration ?? epoch.filterGeneration,
            policyDecisionID: policyDecisionID ?? epoch.policyDecisionID
        )
    }

    private static func queueFrame(
        index: Int,
        epochID: UUID,
        reason: FrameAcceptanceReason
    ) -> QueuedCaptureFrame<String> {
        QueuedCaptureFrame(
            id: uuid(90_000 + index),
            epochID: epochID,
            targetWindowID: 42,
            deliveredNanoseconds: UInt64(index),
            reason: reason,
            shouldIndex: false,
            payload: "frame-\(index)"
        )
    }

    private static func rejectionName(_ decision: FrameAdmissionDecision) -> String {
        switch decision {
        case .accepted:
            "accepted"
        case .rejected(let reason):
            reason.rawValue
        }
    }
}
