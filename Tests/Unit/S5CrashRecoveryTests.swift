import MemoryStore
import XCTest

final class S5CrashRecoveryTests: XCTestCase {
    func testTenThousandFaultInjectedCrashPointsRecoverConsistently() throws {
        let report = try S5CrashRecoveryModel.verify(
            crashPointCount: LM008StoreDefaults.crashPointCount
        )
        XCTAssertEqual(report.crashPointCount, 10_000)
        XCTAssertEqual(report.consistentRecoveryCount, 10_000)
        XCTAssertEqual(report.searchableMissingMediaCount, 0)
        XCTAssertEqual(report.orphanReadyMediaCount, 0)
        XCTAssertEqual(report.boundariesExercised, 10)
    }

    func testInvalidCrashCountFailsClosed() {
        XCTAssertThrowsError(try S5CrashRecoveryModel.verify(crashPointCount: 0))
    }
}
