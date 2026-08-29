import XCTest

@testable import MemorySearch

@MainActor
final class ForgetSessionModelTests: XCTestCase {
    func testProgressProjectionAnnouncesHiddenAndPhysicalDeletionAsSeparateStates() {
        let rewriting = ForgetProgressProjection(
            operation: Self.operation(state: .rewriting, completed: 2, total: 5)
        )
        XCTAssertEqual(rewriting.title, "Hidden from memory")
        XCTAssertEqual(rewriting.completedCount, 2)
        XCTAssertTrue(rewriting.accessibilityLabel.contains("2 of 5"))

        let failed = ForgetProgressProjection(
            operation: Self.operation(state: .failed, completed: 9, total: 5)
        )
        XCTAssertEqual(failed.title, "Deletion needs attention")
        XCTAssertEqual(failed.completedCount, 5)
        XCTAssertTrue(failed.detail.contains("remain hidden"))

        let complete = ForgetProgressProjection(
            operation: Self.operation(state: .complete, completed: 5, total: 5)
        )
        XCTAssertEqual(complete.title, "Deletion verified")
        XCTAssertTrue(complete.detail.contains("complete"))
    }

    func testCancelIsTheDefaultSafePathAndNeverInvokesProvider() async {
        let calls = CallCounter()
        let operation = Self.operation(state: .queued)
        let model = ForgetSessionModel(
            provider: MomentForgetProvider { _ in
                await calls.increment()
                return operation
            }
        )
        let frameID = Self.uuid(1)

        model.begin(.moment(frameID))
        XCTAssertEqual(model.phase, .confirming(.moment(frameID)))
        XCTAssertTrue(model.cancelIsDefault)

        model.cancel()

        XCTAssertEqual(model.phase, .idle)
        let callCount = await calls.currentValue()
        XCTAssertEqual(callCount, 0)
    }

    func testConfirmPublishesImmediateQueuedProgressAndExactHiddenFrames() async {
        let frameID = Self.uuid(2)
        let operation = Self.operation(
            state: .queued,
            affectedFrameIDs: [frameID],
            completed: 0,
            total: 1
        )
        let model = ForgetSessionModel(
            provider: MomentForgetProvider { target in
                XCTAssertEqual(target, .moment(frameID))
                return operation
            }
        )
        model.begin(.moment(frameID))

        let confirmed = await model.confirm()

        XCTAssertEqual(confirmed, operation)
        XCTAssertEqual(model.phase, .processing(operation))
        XCTAssertEqual(model.hiddenFrameIDs, [frameID])
    }

    func testProviderFailureKeepsTargetHiddenOnlyWhenSuppressionWasCommitted() async {
        let target = ForgetTarget.range(
            DateInterval(
                start: Date(timeIntervalSince1970: 100),
                end: Date(timeIntervalSince1970: 200)
            )
        )
        let model = ForgetSessionModel(
            provider: MomentForgetProvider { _ in throw FixtureError.failed }
        )
        model.begin(target)

        let result = await model.confirm()
        XCTAssertNil(result)

        XCTAssertEqual(model.phase, .failure(target: target, diagnosticCode: "LM-DELETE-REQUEST"))
        XCTAssertTrue(model.hiddenFrameIDs.isEmpty)
        model.retry()
        XCTAssertEqual(model.phase, .confirming(target))
    }

    private static func operation(
        state: ForgetOperationState,
        affectedFrameIDs: Set<UUID> = [uuid(9)],
        completed: Int = 0,
        total: Int = 1
    ) -> ForgetOperation {
        ForgetOperation(
            id: uuid(8),
            affectedFrameIDs: affectedFrameIDs,
            state: state,
            completedRewriteCount: completed,
            totalRewriteCount: total,
            failureCode: nil
        )
    }

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "47000000-0000-4000-8000-%012d", suffix))!
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
    func currentValue() -> Int { value }
}

private enum FixtureError: Error {
    case failed
}
