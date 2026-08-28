import Foundation
import MemoryCapture
import MemoryContracts

private struct LM023ActivityRecord: Codable {
    let id: String
    let activity: String
    let suspension: String?
    let acceptsCapture: Bool
    let lastInputClass: String?
}

private struct LM023ActivityReport: Codable {
    let schemaVersion: Int
    let seed: UInt64
    let activeWindowNanoseconds: UInt64
    let idleThresholdNanoseconds: UInt64
    let inputClasses: [String]
    let lifecycleEvents: [String]
    let stateTransitionCount: Int
    let exactStateTransitionCount: Int
    let ignoredSuspendedInputCount: Int
    let activitySignalStoredFieldNames: [String]
    let sensitiveInputPayloadFieldCount: Int
    let idleAcceptanceRejected: Bool
    let activityRecoveryPassed: Bool
    let targetChangeRecoveryPassed: Bool
    let records: [LM023ActivityRecord]
    let allInvariantsPassed: Bool
}

private final class LM023HarnessClock: ActivityMonotonicClock, @unchecked Sendable {
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

private final class LM023BlockingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func set(_ result: Result<Data, Error>) {
        lock.withLock { self.result = result }
    }

    func get() -> Result<Data, Error> {
        lock.withLock { result! }
    }
}

enum LM023ActivityMonitorHarness {
    private static let seed: UInt64 = 1_279_938_623

    static func runBlocking() throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let output = LM023BlockingResult()
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

    private static func run() async throws -> Data {
        let clock = LM023HarnessClock(10_000)
        let monitor = ActivityMonitor(clock: clock)
        var records: [LM023ActivityRecord] = []
        var exactStateTransitionCount = 0
        var ignoredSuspendedInputCount = 0

        func append(
            _ id: String,
            expectedActivity: ActivityState,
            expectedSuspension: ActivitySuspension? = nil,
            expectedInput: ActivityInputClass? = nil
        ) async {
            let snapshot = await monitor.snapshot()
            if snapshot.activity == expectedActivity
                && snapshot.suspension == expectedSuspension
                && snapshot.lastInputClass == expectedInput
            {
                exactStateTransitionCount += 1
            }
            records.append(
                LM023ActivityRecord(
                    id: id,
                    activity: snapshot.activity.rawValue,
                    suspension: snapshot.suspension?.rawValue,
                    acceptsCapture: snapshot.acceptsCapture,
                    lastInputClass: snapshot.lastInputClass?.rawValue
                )
            )
        }

        await append("initial-active", expectedActivity: .active)
        clock.advance(by: ActivityMonitor.activeWindowNanoseconds)
        await append("recently-active-boundary", expectedActivity: .recentlyActive)
        clock.advance(
            by: ActivityMonitor.idleThresholdNanoseconds
                - ActivityMonitor.activeWindowNanoseconds
        )
        await append("five-minute-idle", expectedActivity: .idle)
        await monitor.record(inputClass: .click)
        await append("click-recovers", expectedActivity: .active, expectedInput: .click)

        await monitor.handle(lifecycle: .willSleep)
        await append("sleep-suspends", expectedActivity: .idle, expectedSuspension: .sleep)
        await monitor.record(inputClass: .keyActivity)
        let sleepInput = await monitor.snapshot()
        if sleepInput.lastInputClass == nil {
            ignoredSuspendedInputCount += 1
        }
        await append("sleep-input-ignored", expectedActivity: .idle, expectedSuspension: .sleep)
        await monitor.handle(lifecycle: .didWake)
        await append("wake-needs-activity", expectedActivity: .idle)
        await monitor.record(inputClass: .keyActivity)
        await append(
            "key-activity-recovers",
            expectedActivity: .active,
            expectedInput: .keyActivity
        )

        await monitor.handle(lifecycle: .sessionLocked)
        await append(
            "session-lock-suspends",
            expectedActivity: .idle,
            expectedSuspension: .sessionLocked
        )
        await monitor.record(inputClass: .scroll)
        let lockInput = await monitor.snapshot()
        if lockInput.lastInputClass == nil {
            ignoredSuspendedInputCount += 1
        }
        await append(
            "lock-input-ignored",
            expectedActivity: .idle,
            expectedSuspension: .sessionLocked
        )
        await monitor.handle(lifecycle: .sessionUnlocked)
        await append("unlock-needs-activity", expectedActivity: .idle)
        await monitor.record(inputClass: .scroll)
        await append("scroll-recovers", expectedActivity: .active, expectedInput: .scroll)

        await monitor.handle(lifecycle: .sessionLocked)
        await monitor.handle(lifecycle: .willSleep)
        await append(
            "sleep-precedes-lock",
            expectedActivity: .idle,
            expectedSuspension: .sleep
        )
        await monitor.handle(lifecycle: .didWake)
        await append(
            "wake-remains-locked",
            expectedActivity: .idle,
            expectedSuspension: .sessionLocked
        )
        await monitor.handle(lifecycle: .sessionUnlocked)
        await append("final-unlock-idle", expectedActivity: .idle)

        let acceptanceClock = LM023HarnessClock(1_000)
        let acceptanceMonitor = ActivityMonitor(clock: acceptanceClock)
        var acceptanceGate = FrameAcceptanceGate()
        let epochID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
        _ = acceptanceGate.evaluate(
            epochID: epochID,
            timestampNanoseconds: 1_000,
            signature: 1,
            lastActivityNanoseconds: 1_000
        )
        acceptanceClock.advance(by: ActivityMonitor.idleThresholdNanoseconds)
        let idleSnapshot = await acceptanceMonitor.snapshot()
        let idleDecision = acceptanceGate.evaluate(
            epochID: epochID,
            timestampNanoseconds: acceptanceClock.nowNanoseconds(),
            signature: 2,
            lastActivityNanoseconds: idleSnapshot.lastActivityNanoseconds ?? 0
        )
        await acceptanceMonitor.record(inputClass: .click)
        let recoveredSnapshot = await acceptanceMonitor.snapshot()
        let recoveredDecision = acceptanceGate.evaluate(
            epochID: epochID,
            timestampNanoseconds: acceptanceClock.nowNanoseconds(),
            signature: 2,
            lastActivityNanoseconds: recoveredSnapshot.lastActivityNanoseconds ?? 0
        )
        let nextEpochID = UUID(uuidString: "00000000-0000-0000-0000-000000000024")!
        acceptanceClock.advance(by: ActivityMonitor.idleThresholdNanoseconds)
        let targetChangeDecision = acceptanceGate.evaluate(
            epochID: nextEpochID,
            timestampNanoseconds: acceptanceClock.nowNanoseconds(),
            signature: 3,
            lastActivityNanoseconds: recoveredSnapshot.lastActivityNanoseconds ?? 0
        )

        let activitySignalStoredFieldNames = Mirror(
            reflecting: ActivitySignal(inputClass: .keyActivity, monotonicNanoseconds: 42)
        ).children.compactMap(\.label)
        let idleAcceptanceRejected = idleDecision == .rejected(.idleSuspended)
        let activityRecoveryPassed: Bool
        if case .accepted = recoveredDecision {
            activityRecoveryPassed = true
        } else {
            activityRecoveryPassed = false
        }
        let targetChangeRecoveryPassed: Bool
        if case .accepted(index: true, reason: .firstEpochFrame) = targetChangeDecision {
            targetChangeRecoveryPassed = true
        } else {
            targetChangeRecoveryPassed = false
        }
        let allInvariantsPassed =
            records.count == 15
            && exactStateTransitionCount == records.count
            && ignoredSuspendedInputCount == 2
            && activitySignalStoredFieldNames == ["inputClass", "monotonicNanoseconds"]
            && idleAcceptanceRejected
            && activityRecoveryPassed
            && targetChangeRecoveryPassed

        let report = LM023ActivityReport(
            schemaVersion: 1,
            seed: seed,
            activeWindowNanoseconds: ActivityMonitor.activeWindowNanoseconds,
            idleThresholdNanoseconds: ActivityMonitor.idleThresholdNanoseconds,
            inputClasses: ActivityInputClass.allCases.map(\.rawValue),
            lifecycleEvents: ActivityLifecycleEvent.allCases.map(\.rawValue),
            stateTransitionCount: records.count,
            exactStateTransitionCount: exactStateTransitionCount,
            ignoredSuspendedInputCount: ignoredSuspendedInputCount,
            activitySignalStoredFieldNames: activitySignalStoredFieldNames,
            sensitiveInputPayloadFieldCount: 0,
            idleAcceptanceRejected: idleAcceptanceRejected,
            activityRecoveryPassed: activityRecoveryPassed,
            targetChangeRecoveryPassed: targetChangeRecoveryPassed,
            records: records,
            allInvariantsPassed: allInvariantsPassed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
