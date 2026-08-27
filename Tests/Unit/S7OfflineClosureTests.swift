import MemoryEnrichment
import XCTest

final class S7OfflineClosureTests: XCTestCase {
    func testOfflineJourneyRequiresEveryStageInOrder() throws {
        var tracker = S7OfflineJourneyTracker()
        for stage in S7OfflineJourneyStage.requiredOrder {
            try tracker.complete(stage)
        }

        XCTAssertTrue(tracker.isComplete)
        XCTAssertEqual(tracker.completedStages, S7OfflineJourneyStage.requiredOrder)
    }

    func testOfflineJourneyRejectsSkippedOrRepeatedStages() throws {
        var tracker = S7OfflineJourneyTracker()

        XCTAssertThrowsError(try tracker.complete(.onboarding))
        try tracker.complete(.firstLaunch)
        XCTAssertThrowsError(try tracker.complete(.firstLaunch))
        XCTAssertThrowsError(try tracker.complete(.search))
    }

    func testProvenanceRequiresCompleteImmutableIdentity() {
        XCTAssertTrue(S7ProvenanceRecord(
            path: "Local Memory.app/Contents/MacOS/Local Memory",
            source: "DeepShelves source tree",
            version: "0.1.0",
            license: "Private personal-use source",
            sha256: String(repeating: "a", count: 64),
            updateProcedure: "Rebuild from a reviewed story and rerun S7."
        ).isComplete)

        XCTAssertFalse(S7ProvenanceRecord(
            path: "resource",
            source: "",
            version: "0.1.0",
            license: "MIT",
            sha256: "ABC",
            updateProcedure: ""
        ).isComplete)
    }
}
