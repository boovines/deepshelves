import Foundation
import MemoryContracts
import XCTest

@testable import MemoryEnrichment
@testable import MemoryStore

final class EnrichmentSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_800_000)

    func testPriorityAndBacklogKeepCaptureTransitionAheadOfHeartbeat() async throws {
        let store = try ArchiveEnrichmentJobStore(
            database: ArchiveDatabase.deterministicTestStore()
        )
        let heartbeatID = try XCTUnwrap(
            UUID(uuidString: "34000000-0000-0000-0000-000000000001")
        )
        let transitionID = try XCTUnwrap(
            UUID(uuidString: "34000000-0000-0000-0000-000000000002")
        )
        try store.enqueue(
            EnrichmentJobSeed(
                id: heartbeatID,
                parentID: UUID(),
                kind: .thumbnail,
                priority: EnrichmentJobPriority.heartbeat,
                producerVersion: "thumbnail-v1"
            )
        )
        try store.enqueue(
            EnrichmentJobSeed(
                id: transitionID,
                parentID: UUID(),
                kind: .thumbnail,
                priority: EnrichmentJobPriority.captureTransition,
                producerVersion: "thumbnail-v1"
            )
        )
        let scheduler = EnrichmentScheduler(
            store: store,
            producerVersions: [.thumbnail: "thumbnail-v1"]
        )

        let outcome = try await scheduler.runNext(
            conditions: .idleOnExternalPower,
            now: now
        ) { lease in
            XCTAssertEqual(lease.jobID, transitionID)
        }

        guard case .succeeded(let lease) = outcome else {
            return XCTFail("expected the transition-priority job to succeed")
        }
        XCTAssertEqual(lease.jobID, transitionID)
        let backlog = try await scheduler.backlog(now: now)
        XCTAssertEqual(backlog.totalPending, 1)
        XCTAssertEqual(backlog.ready, 1)
        XCTAssertEqual(backlog.succeeded, 1)
        XCTAssertEqual(backlog.byKind[.thumbnail]?.queued, 1)
        XCTAssertEqual(backlog.presentation.statusText, "Indexing 1 item")
    }

    func testCapturePowerIdleAndThermalThrottlesDoNotConsumeDeferredWork() async throws {
        let store = try ArchiveEnrichmentJobStore(
            database: ArchiveDatabase.deterministicTestStore()
        )
        let jobID = UUID()
        try store.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: UUID(),
                kind: .visionOCR,
                priority: EnrichmentJobPriority.heartbeat,
                producerVersion: "ocr-v1"
            )
        )
        let scheduler = EnrichmentScheduler(
            store: store,
            producerVersions: [.visionOCR: "ocr-v1"]
        )

        let captureDeferred = try await scheduler.runNext(
            conditions: EnrichmentRuntimeConditions(
                isUserIdle: true,
                powerSource: .external,
                batteryLevel: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                captureTransitionPending: true
            ),
            now: now,
            operation: { _ in XCTFail("capture must win") }
        )
        XCTAssertEqual(captureDeferred, .deferred(.captureTransitionPending))
        let thermalDeferred = try await scheduler.runNext(
            conditions: EnrichmentRuntimeConditions(
                isUserIdle: true,
                powerSource: .external,
                batteryLevel: nil,
                lowPowerModeEnabled: false,
                thermalState: .critical,
                captureTransitionPending: false
            ),
            now: now,
            operation: { _ in XCTFail("critical thermal state must defer") }
        )
        XCTAssertEqual(thermalDeferred, .deferred(.thermalPressure))
        let activeDeferred = try await scheduler.runNext(
            conditions: EnrichmentRuntimeConditions(
                isUserIdle: false,
                powerSource: .external,
                batteryLevel: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                captureTransitionPending: false
            ),
            now: now,
            operation: { _ in XCTFail("heartbeat requires idle time") }
        )
        XCTAssertEqual(activeDeferred, .deferred(.noEligibleWork))
        let powerDeferred = try await scheduler.runNext(
            conditions: EnrichmentRuntimeConditions(
                isUserIdle: true,
                powerSource: .battery,
                batteryLevel: 0.15,
                lowPowerModeEnabled: true,
                thermalState: .fair,
                captureTransitionPending: false
            ),
            now: now,
            operation: { _ in XCTFail("heartbeat must wait") }
        )
        XCTAssertEqual(powerDeferred, .deferred(.noEligibleWork))
        let backlog = try await scheduler.backlog(now: now)
        XCTAssertEqual(backlog.ready, 1)
        XCTAssertEqual(backlog.leased, 0)
        XCTAssertEqual(backlog.totalPending, 1)
    }

    func testThreeAttemptPolicyBecomesPermanentAndUsesContentFreeError() async throws {
        let store = try ArchiveEnrichmentJobStore(
            database: ArchiveDatabase.deterministicTestStore()
        )
        let jobID = UUID()
        try store.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: UUID(),
                kind: .visionOCR,
                priority: EnrichmentJobPriority.fastOCR,
                producerVersion: "ocr-v1"
            )
        )
        let scheduler = EnrichmentScheduler(
            store: store,
            producerVersions: [.visionOCR: "ocr-v1"]
        )
        var attemptTime = now
        for attempt in 1...3 {
            let outcome = try await scheduler.runNext(
                conditions: .idleOnExternalPower,
                now: attemptTime
            ) { _ in
                throw FixtureFailure.failed
            }
            if attempt < 3 {
                guard case .retryScheduled(let lease, let retryAt) = outcome else {
                    return XCTFail("attempt \(attempt) should retry")
                }
                XCTAssertEqual(lease.attemptCount, attempt)
                attemptTime = retryAt.addingTimeInterval(0.001)
            } else {
                guard case .permanentlyFailed(let lease) = outcome else {
                    return XCTFail("third attempt should become permanent")
                }
                XCTAssertEqual(lease.attemptCount, 3)
            }
        }

        let record = try XCTUnwrap(try store.job(jobID))
        XCTAssertEqual(record.state, .permanentFailure)
        XCTAssertEqual(record.attemptCount, ProcessingJob.maximumAutomaticAttempts)
        XCTAssertEqual(record.lastErrorCode, EnrichmentScheduler.processingErrorCode)
        let backlog = try await scheduler.backlog(now: attemptTime)
        XCTAssertEqual(backlog.totalPending, 0)
        XCTAssertEqual(backlog.permanentFailures, 1)
        XCTAssertEqual(backlog.presentation.statusText, "Indexing failed for 1 item")
    }

    func testProducerVersionInvalidationRequeuesSucceededWorkExactlyOnce() async throws {
        let store = try ArchiveEnrichmentJobStore(
            database: ArchiveDatabase.deterministicTestStore()
        )
        let jobID = UUID()
        try store.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: UUID(),
                kind: .thumbnail,
                priority: EnrichmentJobPriority.thumbnail,
                producerVersion: "thumbnail-v1"
            )
        )
        let first = EnrichmentScheduler(
            store: store,
            producerVersions: [.thumbnail: "thumbnail-v1"]
        )
        guard
            case .succeeded = try await first.runNext(
                conditions: .idleOnExternalPower,
                now: now,
                operation: { _ in }
            )
        else {
            return XCTFail("first producer should complete")
        }

        let replacement = EnrichmentScheduler(
            store: store,
            producerVersions: [.thumbnail: "thumbnail-v2"]
        )
        let invalidated = try await replacement.synchronizeProducerVersions()
        XCTAssertEqual(invalidated, 1)
        let secondInvalidation = try await replacement.synchronizeProducerVersions()
        XCTAssertEqual(secondInvalidation, 0)
        let backlog = try await replacement.backlog(now: now)
        XCTAssertEqual(backlog.ready, 1)
        XCTAssertEqual(backlog.succeeded, 0)
        guard
            case .succeeded(let lease) = try await replacement.runNext(
                conditions: .idleOnExternalPower,
                now: now,
                operation: { _ in }
            )
        else {
            return XCTFail("replacement producer should rerun the job")
        }
        XCTAssertEqual(lease.producerVersion, "thumbnail-v2")
        XCTAssertEqual(lease.attemptCount, 1)
    }

    func testExpiredLeaseIsRecoveredAndOldWorkerCannotPublish() throws {
        let store = try ArchiveEnrichmentJobStore(
            database: ArchiveDatabase.deterministicTestStore()
        )
        let jobID = UUID()
        try store.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: UUID(),
                kind: .thumbnail,
                priority: EnrichmentJobPriority.thumbnail,
                producerVersion: "thumbnail-v1"
            )
        )
        let first = try XCTUnwrap(
            try store.leaseNext(
                now: now,
                leaseDuration: 1,
                minimumPriority: 0,
                producerVersions: [.thumbnail: "thumbnail-v1"]
            )
        )
        let afterExpiry = now.addingTimeInterval(2)
        let backlog = try store.backlog(now: afterExpiry)
        XCTAssertEqual(backlog.leased, 0)
        XCTAssertEqual(backlog.ready, 1)
        let replacement = try XCTUnwrap(
            try store.leaseNext(
                now: afterExpiry,
                leaseDuration: EnrichmentScheduler.leaseDuration,
                minimumPriority: 0,
                producerVersions: [.thumbnail: "thumbnail-v1"]
            )
        )
        XCTAssertEqual(replacement.attemptCount, 2)
        XCTAssertThrowsError(try store.succeed(first)) { error in
            XCTAssertEqual(error as? ArchiveEnrichmentJobStoreError, .staleLease)
        }
        XCTAssertNoThrow(try store.succeed(replacement))
    }

    func testProcessRestartRequeuesDurableLeaseWithoutLosingAttemptCount() throws {
        let fixture = try SchedulerArchiveFixture()
        defer { fixture.remove() }
        let jobID = UUID()
        var archive: ArchiveDatabase? = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        var store: ArchiveEnrichmentJobStore? = try ArchiveEnrichmentJobStore(
            database: try XCTUnwrap(archive)
        )
        try store?.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: UUID(),
                kind: .thumbnail,
                priority: EnrichmentJobPriority.thumbnail,
                producerVersion: "thumbnail-v1"
            )
        )
        let firstLease = try XCTUnwrap(
            try store?.leaseNext(
                now: now,
                leaseDuration: EnrichmentScheduler.leaseDuration,
                minimumPriority: 0,
                producerVersions: [.thumbnail: "thumbnail-v1"]
            )
        )
        XCTAssertEqual(firstLease.attemptCount, 1)
        store = nil
        archive = nil

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(reopened.startupRecoveryReport.requeuedLeasedJobs, 1)
        let recoveredStore = try ArchiveEnrichmentJobStore(database: reopened)
        let recovered = try XCTUnwrap(
            try recoveredStore.leaseNext(
                now: now.addingTimeInterval(1),
                leaseDuration: EnrichmentScheduler.leaseDuration,
                minimumPriority: 0,
                producerVersions: [.thumbnail: "thumbnail-v1"]
            )
        )
        XCTAssertEqual(recovered.jobID, jobID)
        XCTAssertEqual(recovered.attemptCount, 2)
    }
}

private enum FixtureFailure: Error { case failed }

private struct SchedulerArchiveFixture {
    let root: URL
    let applicationSupport: URL
    let encryptionKey = Data(repeating: 0x34, count: LM008StoreDefaults.keyByteCount)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm034-scheduler-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        applicationSupport = root.appending(
            path: "Application Support",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
