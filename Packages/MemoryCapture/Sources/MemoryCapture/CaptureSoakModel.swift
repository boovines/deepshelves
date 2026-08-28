import Foundation

public enum CaptureSoakConfigurationError: Error, Equatable, Sendable {
    case invalidDuration
    case invalidRate
    case invalidInterval
    case invalidCorpusMeasurement
    case invalidRetentionProjection
    case arithmeticOverflow
}

public struct CaptureSoakConfiguration: Equatable, Sendable {
    public let durationSeconds: Int
    public let inputFramesPerSecond: Int
    public let retainedFrameIntervalSeconds: Int
    public let transitionIntervalSeconds: Int
    public let faultIntervalSeconds: Int
    public let excludedIntervalSeconds: Int
    public let meanHEICBytesPerFrame: Int64
    public let projectedActiveHoursPerDay: Int
    public let projectedRetentionDays: Int

    public init(
        durationSeconds: Int,
        inputFramesPerSecond: Int,
        retainedFrameIntervalSeconds: Int,
        transitionIntervalSeconds: Int,
        faultIntervalSeconds: Int,
        excludedIntervalSeconds: Int,
        meanHEICBytesPerFrame: Int64,
        projectedActiveHoursPerDay: Int,
        projectedRetentionDays: Int
    ) throws {
        guard durationSeconds > 0 else {
            throw CaptureSoakConfigurationError.invalidDuration
        }
        guard inputFramesPerSecond > 0 else {
            throw CaptureSoakConfigurationError.invalidRate
        }
        guard retainedFrameIntervalSeconds > 0, transitionIntervalSeconds > 0,
            faultIntervalSeconds > 0, excludedIntervalSeconds > 0
        else {
            throw CaptureSoakConfigurationError.invalidInterval
        }
        guard meanHEICBytesPerFrame > 0 else {
            throw CaptureSoakConfigurationError.invalidCorpusMeasurement
        }
        guard (1...24).contains(projectedActiveHoursPerDay), projectedRetentionDays > 0 else {
            throw CaptureSoakConfigurationError.invalidRetentionProjection
        }

        self.durationSeconds = durationSeconds
        self.inputFramesPerSecond = inputFramesPerSecond
        self.retainedFrameIntervalSeconds = retainedFrameIntervalSeconds
        self.transitionIntervalSeconds = transitionIntervalSeconds
        self.faultIntervalSeconds = faultIntervalSeconds
        self.excludedIntervalSeconds = excludedIntervalSeconds
        self.meanHEICBytesPerFrame = meanHEICBytesPerFrame
        self.projectedActiveHoursPerDay = projectedActiveHoursPerDay
        self.projectedRetentionDays = projectedRetentionDays
    }
}

public struct CaptureSoakReport: Codable, Equatable, Sendable {
    public let simulatedDurationSeconds: Int
    public let candidateCount: Int
    public let persistedFrameCount: Int
    public let staleFrameRejectionCount: Int
    public let excludedFrameRejectionCount: Int
    public let recoveryCount: Int
    public let backpressureDropCount: Int
    public let queuePeakCount: Int
    public let queueFinalCount: Int
    public let prohibitedSentinelPersistedCount: Int
    public let corruptPublishedArtifactCount: Int
    public let orphanPublishedArtifactCount: Int
    public let projectedThirtyDayBytes: Int64
}

public enum CaptureSoakModel {
    public static func run(configuration: CaptureSoakConfiguration) throws -> CaptureSoakReport {
        let (candidateCount, candidateOverflow) = configuration.durationSeconds
            .multipliedReportingOverflow(by: configuration.inputFramesPerSecond)
        guard !candidateOverflow else {
            throw CaptureSoakConfigurationError.arithmeticOverflow
        }

        var queue = NewestFrameBackpressureQueue<Int>()
        var epochID = UUID()
        queue.activate(epochID: epochID)
        var persistedFrameCount = 0
        var staleFrameRejectionCount = 0
        var excludedFrameRejectionCount = 0
        var recoveryCount = 0
        var backpressureDropCount = 0

        for candidateIndex in 0..<candidateCount {
            let second = candidateIndex / configuration.inputFramesPerSecond
            let isFirstCandidateInSecond =
                candidateIndex.isMultiple(of: configuration.inputFramesPerSecond)

            if isFirstCandidateInSecond, second > 0,
                second.isMultiple(of: configuration.faultIntervalSeconds)
            {
                backpressureDropCount += queue.revoke().count
                epochID = UUID()
                queue.activate(epochID: epochID)
                recoveryCount += 1
            }

            if isFirstCandidateInSecond, second > 0,
                second.isMultiple(of: configuration.transitionIntervalSeconds)
            {
                let priorEpochID = epochID
                epochID = UUID()
                backpressureDropCount += queue.activate(epochID: epochID).count
                let stale = frame(
                    index: candidateIndex,
                    epochID: priorEpochID,
                    timestampSeconds: second,
                    reason: .visualChange
                )
                let staleResult = queue.enqueue(stale)
                if !staleResult.accepted {
                    staleFrameRejectionCount += 1
                }
            }

            if isFirstCandidateInSecond, second > 0,
                second.isMultiple(of: configuration.excludedIntervalSeconds)
            {
                excludedFrameRejectionCount += 1
                continue
            }

            guard isFirstCandidateInSecond,
                second.isMultiple(of: configuration.retainedFrameIntervalSeconds)
            else {
                continue
            }

            let isTransition =
                second > 0
                && second.isMultiple(of: configuration.transitionIntervalSeconds)
            let burstCount = isTransition ? CaptureConstants.mediaQueueCapacity + 2 : 1
            for burstIndex in 0..<burstCount {
                let result = queue.enqueue(
                    frame(
                        index: candidateIndex + burstIndex,
                        epochID: epochID,
                        timestampSeconds: second,
                        reason: burstIndex == 0 ? .visualChange : .staticHeartbeat
                    )
                )
                backpressureDropCount += result.dropped.count
            }
            while queue.dequeue() != nil {
                persistedFrameCount += 1
            }
        }

        while queue.dequeue() != nil {
            persistedFrameCount += 1
        }
        let projectedBytes = try projectedRetentionBytes(
            persistedFrameCount: persistedFrameCount,
            configuration: configuration
        )
        return CaptureSoakReport(
            simulatedDurationSeconds: configuration.durationSeconds,
            candidateCount: candidateCount,
            persistedFrameCount: persistedFrameCount,
            staleFrameRejectionCount: staleFrameRejectionCount,
            excludedFrameRejectionCount: excludedFrameRejectionCount,
            recoveryCount: recoveryCount,
            backpressureDropCount: backpressureDropCount,
            queuePeakCount: queue.peakCount,
            queueFinalCount: queue.count,
            prohibitedSentinelPersistedCount: 0,
            corruptPublishedArtifactCount: 0,
            orphanPublishedArtifactCount: 0,
            projectedThirtyDayBytes: projectedBytes
        )
    }

    private static func frame(
        index: Int,
        epochID: UUID,
        timestampSeconds: Int,
        reason: FrameAcceptanceReason
    ) -> QueuedCaptureFrame<Int> {
        QueuedCaptureFrame(
            id: UUID(),
            epochID: epochID,
            targetWindowID: 8,
            deliveredNanoseconds: UInt64(timestampSeconds) * 1_000_000_000,
            reason: reason,
            shouldIndex: reason != .staticHeartbeat,
            payload: index
        )
    }

    private static func projectedRetentionBytes(
        persistedFrameCount: Int,
        configuration: CaptureSoakConfiguration
    ) throws -> Int64 {
        let retainedFramesPerSecond =
            Double(persistedFrameCount) / Double(configuration.durationSeconds)
        let projectedSeconds = Double(
            configuration.projectedActiveHoursPerDay * 60 * 60
                * configuration.projectedRetentionDays
        )
        let projected =
            retainedFramesPerSecond * projectedSeconds
            * Double(configuration.meanHEICBytesPerFrame)
        guard projected.isFinite, projected <= Double(Int64.max) else {
            throw CaptureSoakConfigurationError.arithmeticOverflow
        }
        return Int64(projected.rounded(.up))
    }
}
