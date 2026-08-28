import Foundation
import MemoryContracts
import MemoryStore

public enum EnrichmentJobPriority {
    public static let captureTransition = 1_000
    public static let metadata = 950
    public static let accessibility = 900
    public static let thumbnail = 800
    public static let fastOCR = 700
    public static let visualEmbedding = 500
    public static let accurateOCR = 250
    public static let heartbeat = 100
    public static let maintenance = 50
}

public enum EnrichmentPowerSource: String, Codable, Equatable, Sendable {
    case external
    case battery
}

public enum EnrichmentThermalState: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct EnrichmentRuntimeConditions: Equatable, Sendable {
    public let isUserIdle: Bool
    public let powerSource: EnrichmentPowerSource
    public let batteryLevel: Double?
    public let lowPowerModeEnabled: Bool
    public let thermalState: EnrichmentThermalState
    public let captureTransitionPending: Bool

    public init(
        isUserIdle: Bool,
        powerSource: EnrichmentPowerSource,
        batteryLevel: Double?,
        lowPowerModeEnabled: Bool,
        thermalState: EnrichmentThermalState,
        captureTransitionPending: Bool
    ) {
        self.isUserIdle = isUserIdle
        self.powerSource = powerSource
        self.batteryLevel = batteryLevel
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.captureTransitionPending = captureTransitionPending
    }

    public static let idleOnExternalPower = EnrichmentRuntimeConditions(
        isUserIdle: true,
        powerSource: .external,
        batteryLevel: nil,
        lowPowerModeEnabled: false,
        thermalState: .nominal,
        captureTransitionPending: false
    )
}

public protocol EnrichmentRuntimeConditionProviding: Sendable {
    func currentConditions() async -> EnrichmentRuntimeConditions
}

public enum EnrichmentSchedulerDeferralReason: String, Codable, Equatable, Sendable {
    case captureTransitionPending
    case thermalPressure
    case noEligibleWork
}

public enum EnrichmentSchedulerOutcome: Equatable, Sendable {
    case succeeded(EnrichmentJobLease)
    case retryScheduled(EnrichmentJobLease, Date)
    case permanentlyFailed(EnrichmentJobLease)
    case cancelled(EnrichmentJobLease)
    case deferred(EnrichmentSchedulerDeferralReason)
    case noWork
}

public struct EnrichmentBacklogPresentation: Equatable, Sendable {
    public let pendingCount: Int
    public let failedCount: Int
    public let statusText: String
    public let accessibilityValue: String
    public let visualPendingCount: Int
    public let visualFailedCount: Int
    public let visualStatusText: String

    public init(
        pendingCount: Int,
        failedCount: Int,
        statusText: String,
        accessibilityValue: String,
        visualPendingCount: Int = 0,
        visualFailedCount: Int = 0,
        visualStatusText: String = "Visual search up to date"
    ) {
        self.pendingCount = pendingCount
        self.failedCount = failedCount
        self.statusText = statusText
        self.accessibilityValue = accessibilityValue
        self.visualPendingCount = visualPendingCount
        self.visualFailedCount = visualFailedCount
        self.visualStatusText = visualStatusText
    }
}

extension EnrichmentBacklogSnapshot {
    public var presentation: EnrichmentBacklogPresentation {
        let visual = byKind[.visualVector] ?? EnrichmentBacklogCounts()
        let visualPending = visual.queued + visual.leased + visual.retryScheduled
        let visualNoun = visualPending == 1 ? "item" : "items"
        let visualFailedNoun = visual.permanentFailures == 1 ? "item" : "items"
        let visualStatusText: String
        if visualPending > 0 {
            visualStatusText = "Visual search indexing: \(visualPending) \(visualNoun) remaining"
        } else if visual.permanentFailures > 0 {
            visualStatusText =
                "Visual search unavailable for \(visual.permanentFailures) \(visualFailedNoun)"
        } else {
            visualStatusText = "Visual search up to date"
        }
        let pendingNoun = totalPending == 1 ? "item" : "items"
        let failedNoun = permanentFailures == 1 ? "item" : "items"
        let statusText: String
        if totalPending > 0 {
            statusText = "Indexing \(totalPending) \(pendingNoun)"
        } else if permanentFailures > 0 {
            statusText = "Indexing failed for \(permanentFailures) \(failedNoun)"
        } else {
            statusText = "Indexing up to date"
        }
        let accessibilityValue =
            "\(totalPending) pending, \(leased) active, "
            + "\(retryScheduled) retrying, \(permanentFailures) failed, "
            + "\(visualPending) visual pending"
        return EnrichmentBacklogPresentation(
            pendingCount: totalPending,
            failedCount: permanentFailures,
            statusText: statusText,
            accessibilityValue: accessibilityValue,
            visualPendingCount: visualPending,
            visualFailedCount: visual.permanentFailures,
            visualStatusText: visualStatusText
        )
    }
}

public actor EnrichmentScheduler {
    public static let leaseDuration: TimeInterval = 120
    public static let processingErrorCode = "enrichment_failed"

    private let store: ArchiveEnrichmentJobStore
    private let producerVersions: [ProcessingJobKind: String]

    public init(
        store: ArchiveEnrichmentJobStore,
        producerVersions: [ProcessingJobKind: String]
    ) {
        self.store = store
        self.producerVersions = producerVersions
    }

    @discardableResult
    public func synchronizeProducerVersions() throws -> Int {
        try store.synchronizeProducerVersions(producerVersions)
    }

    public func backlog(now: Date) throws -> EnrichmentBacklogSnapshot {
        try store.backlog(now: now)
    }

    public func runNext(
        conditions: EnrichmentRuntimeConditions,
        now: Date,
        operation: @escaping @Sendable (EnrichmentJobLease) async throws -> Void
    ) async throws -> EnrichmentSchedulerOutcome {
        _ = try synchronizeProducerVersions()
        if conditions.captureTransitionPending {
            return .deferred(.captureTransitionPending)
        }
        guard conditions.thermalState != .critical else {
            return .deferred(.thermalPressure)
        }

        let minimumPriority = Self.minimumPriority(for: conditions)
        guard
            let lease = try store.leaseNext(
                now: now,
                leaseDuration: Self.leaseDuration,
                minimumPriority: minimumPriority,
                producerVersions: producerVersions
            )
        else {
            return try store.backlog(now: now).totalPending == 0
                ? .noWork
                : .deferred(.noEligibleWork)
        }

        do {
            try await operation(lease)
            try Task.checkCancellation()
            try store.succeed(lease)
            return .succeeded(lease)
        } catch is CancellationError {
            try store.cancel(lease)
            return .cancelled(lease)
        } catch {
            let retryAt = now.addingTimeInterval(Self.retryDelay(after: lease.attemptCount))
            let state = try store.fail(
                lease,
                errorCode: Self.processingErrorCode,
                retryAt: retryAt
            )
            if state == .retryableFailure {
                return .retryScheduled(lease, retryAt)
            }
            return .permanentlyFailed(lease)
        }
    }

    private static func minimumPriority(for conditions: EnrichmentRuntimeConditions) -> Int {
        if conditions.thermalState == .serious
            || conditions.lowPowerModeEnabled
            || (conditions.powerSource == .battery
                && (conditions.batteryLevel ?? 1) <= 0.20)
        {
            return EnrichmentJobPriority.fastOCR
        }
        if !conditions.isUserIdle {
            return EnrichmentJobPriority.visualEmbedding
        }
        return 0
    }

    private static func retryDelay(after attempt: Int) -> TimeInterval {
        min(60, 5 * pow(2, Double(max(0, attempt - 1))))
    }
}
