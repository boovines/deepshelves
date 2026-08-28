import MemoryCapture
import XCTest

final class CaptureSoakModelTests: XCTestCase {
    func testEightHourOfficeModelKeepsQueueBoundedAndProjectsThirtyDayStorage() throws {
        let report = try CaptureSoakModel.run(
            configuration: CaptureSoakConfiguration(
                durationSeconds: 8 * 60 * 60,
                inputFramesPerSecond: 2,
                retainedFrameIntervalSeconds: 10,
                transitionIntervalSeconds: 5 * 60,
                faultIntervalSeconds: 47 * 60,
                excludedIntervalSeconds: 13 * 60,
                meanHEICBytesPerFrame: 200_000,
                projectedActiveHoursPerDay: 8,
                projectedRetentionDays: 30
            )
        )

        XCTAssertEqual(report.simulatedDurationSeconds, 28_800)
        XCTAssertEqual(report.candidateCount, 57_600)
        XCTAssertGreaterThan(report.persistedFrameCount, 0)
        XCTAssertGreaterThan(report.staleFrameRejectionCount, 0)
        XCTAssertGreaterThan(report.excludedFrameRejectionCount, 0)
        XCTAssertGreaterThan(report.recoveryCount, 0)
        XCTAssertLessThanOrEqual(report.queuePeakCount, CaptureConstants.mediaQueueCapacity)
        XCTAssertEqual(report.queueFinalCount, 0)
        XCTAssertEqual(report.prohibitedSentinelPersistedCount, 0)
        XCTAssertLessThan(report.projectedThirtyDayBytes, 20 * 1_000_000_000)
    }

    func testSeventyTwoHourAcceleratedModelDoesNotLeakOrGrowQueues() throws {
        let report = try CaptureSoakModel.run(
            configuration: CaptureSoakConfiguration(
                durationSeconds: 72 * 60 * 60,
                inputFramesPerSecond: 2,
                retainedFrameIntervalSeconds: 10,
                transitionIntervalSeconds: 90,
                faultIntervalSeconds: 11 * 60,
                excludedIntervalSeconds: 7 * 60,
                meanHEICBytesPerFrame: 200_000,
                projectedActiveHoursPerDay: 8,
                projectedRetentionDays: 30
            )
        )

        XCTAssertEqual(report.simulatedDurationSeconds, 259_200)
        XCTAssertEqual(report.candidateCount, 518_400)
        XCTAssertLessThanOrEqual(report.queuePeakCount, CaptureConstants.mediaQueueCapacity)
        XCTAssertEqual(report.queueFinalCount, 0)
        XCTAssertEqual(report.prohibitedSentinelPersistedCount, 0)
        XCTAssertEqual(report.corruptPublishedArtifactCount, 0)
        XCTAssertEqual(report.orphanPublishedArtifactCount, 0)
    }

    func testInvalidOrStorageHungryConfigurationFailsClosed() throws {
        XCTAssertThrowsError(
            try CaptureSoakConfiguration(
                durationSeconds: 0,
                inputFramesPerSecond: 2,
                retainedFrameIntervalSeconds: 10,
                transitionIntervalSeconds: 300,
                faultIntervalSeconds: 2_820,
                excludedIntervalSeconds: 780,
                meanHEICBytesPerFrame: 200_000,
                projectedActiveHoursPerDay: 8,
                projectedRetentionDays: 30
            )
        )

        let report = try CaptureSoakModel.run(
            configuration: CaptureSoakConfiguration(
                durationSeconds: 8 * 60 * 60,
                inputFramesPerSecond: 2,
                retainedFrameIntervalSeconds: 1,
                transitionIntervalSeconds: 300,
                faultIntervalSeconds: 2_820,
                excludedIntervalSeconds: 780,
                meanHEICBytesPerFrame: 700_000,
                projectedActiveHoursPerDay: 8,
                projectedRetentionDays: 30
            )
        )
        XCTAssertGreaterThan(report.projectedThirtyDayBytes, 20 * 1_000_000_000)
    }
}
