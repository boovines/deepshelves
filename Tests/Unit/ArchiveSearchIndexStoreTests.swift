import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveSearchIndexStoreTests: XCTestCase {
    func testSchemaV3UsesMergedRecordsAsExplicitExternalFTSContent() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()

        XCTAssertEqual(
            try archive.appliedMigrationIdentifiers(),
            ["v1_archive_schema", "v2_heic_frame_locators", "v3_merged_text_fts"]
        )
        XCTAssertEqual(try archive.archiveMetaValue(forKey: "schema_version"), "3")
        XCTAssertEqual(try archive.archiveMetaValue(forKey: "contract_version"), "2")
        let schema = try archive.schemaSQL()
        XCTAssertTrue(schema.contains("CREATE TABLE merged_text_records"))
        XCTAssertTrue(schema.contains("content='merged_text_records'"))
        XCTAssertTrue(schema.contains("transcript_text"))
        XCTAssertFalse(schema.contains("CREATE TRIGGER merged_text"))
    }

    func testPublishIndexesApprovedTextAndCanonicalMetadata() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = try archive.insertSearchFrameFixtureForTesting(
            suffix: 1,
            appName: "Example Editor",
            windowTitle: "Quarterly Plan",
            host: "docs.example.com",
            path: "/approved/roadmap"
        )
        let store = ArchiveSearchIndexStore(database: archive)
        let spans = try [
            textSpan(suffix: 1, frameID: frameID, source: .accessibility, text: "Focused text"),
            textSpan(suffix: 2, frameID: frameID, source: .visionOCR, text: "OCR evidence"),
        ]
        let transcripts = try [
            textSpan(
                suffix: 3,
                frameID: frameID,
                source: .transcript,
                text: "Reserved audio evidence"
            )
        ]

        let record = try store.publish(
            ArchiveMergedTextSeed(
                frameID: frameID,
                approvedSpans: spans,
                transcriptSpans: transcripts,
                producerVersion: "merged-text-v1"
            )
        )

        XCTAssertEqual(record.approvedText, "Focused text\nOCR evidence")
        XCTAssertEqual(record.transcriptText, "Reserved audio evidence")
        XCTAssertEqual(record.applicationName, "Example Editor")
        XCTAssertEqual(record.windowTitle, "Quarterly Plan")
        XCTAssertEqual(record.urlHost, "docs.example.com")
        XCTAssertEqual(record.urlPath, "/approved/roadmap")
        for query in ["focused", "quarterly", "editor", "docs", "roadmap", "audio"] {
            XCTAssertEqual(try store.matchingFrameIDsForTesting(query: query), [frameID])
        }
        let integrity = try store.integritySnapshot()
        XCTAssertEqual(integrity.readyFrameCount, 1)
        XCTAssertEqual(integrity.readyMergedRecordCount, 1)
        XCTAssertEqual(integrity.indexedRowCount, 1)
        XCTAssertTrue(integrity.isConsistent)
    }

    func testUpdateExplicitlyRemovesOldTermsAndKeepsStableExternalRow() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = try archive.insertSearchFrameFixtureForTesting(suffix: 2)
        let store = ArchiveSearchIndexStore(database: archive)
        let firstRowID = try store.publish(
            seed(frameID: frameID, suffix: 10, text: "obsolete sentinel")
        ).rowID

        let secondRowID = try store.publish(
            seed(frameID: frameID, suffix: 11, text: "replacement evidence")
        ).rowID

        XCTAssertEqual(firstRowID, secondRowID)
        XCTAssertTrue(try store.matchingFrameIDsForTesting(query: "obsolete").isEmpty)
        XCTAssertEqual(try store.matchingFrameIDsForTesting(query: "replacement"), [frameID])
        XCTAssertEqual(try store.mergedRecordCountForTesting(), 1)
        XCTAssertTrue(try store.integritySnapshot().isConsistent)
    }

    func testFailedMidTransactionUpdatePreservesOldSpansRecordAndIndex() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let firstFrame = try archive.insertSearchFrameFixtureForTesting(suffix: 21)
        let secondFrame = try archive.insertSearchFrameFixtureForTesting(suffix: 22)
        let store = ArchiveSearchIndexStore(database: archive)
        _ = try store.publish(seed(frameID: firstFrame, suffix: 210, text: "durable original"))
        _ = try store.publish(seed(frameID: secondFrame, suffix: 220, text: "other evidence"))
        let collidingSpan = try textSpan(
            suffix: 220,
            frameID: firstFrame,
            source: .accessibility,
            text: "must roll back"
        )

        XCTAssertThrowsError(
            try store.publish(
                ArchiveMergedTextSeed(
                    frameID: firstFrame,
                    approvedSpans: [collidingSpan],
                    transcriptSpans: [],
                    producerVersion: "merged-text-v2"
                )
            )
        )

        XCTAssertEqual(
            try store.matchingFrameIDsForTesting(query: "original"),
            [firstFrame]
        )
        XCTAssertTrue(try store.matchingFrameIDsForTesting(query: "rollback").isEmpty)
        XCTAssertTrue(try store.integritySnapshot().isConsistent)
    }

    func testDeleteRemovesFrameSpansMergedRecordAndFTSEvidenceAtomically() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = try archive.insertSearchFrameFixtureForTesting(suffix: 3)
        let store = ArchiveSearchIndexStore(database: archive)
        _ = try store.publish(seed(frameID: frameID, suffix: 20, text: "forensic sentinel"))

        try store.deleteFrameAndSearchEvidence(frameID: frameID)

        XCTAssertTrue(try store.matchingFrameIDsForTesting(query: "forensic").isEmpty)
        XCTAssertEqual(try store.mergedRecordCountForTesting(), 0)
        XCTAssertEqual(try store.textSpanCountForTesting(frameID: frameID), 0)
        XCTAssertFalse(try store.frameExistsForTesting(frameID: frameID))
        XCTAssertTrue(try store.integritySnapshot().isConsistent)
    }

    func testRebuildRepairsMissingAndStaleRowsToExactReadyFrameParity() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let store = ArchiveSearchIndexStore(database: archive)
        let first = try archive.insertSearchFrameFixtureForTesting(suffix: 4)
        let second = try archive.insertSearchFrameFixtureForTesting(suffix: 5)
        _ = try store.publish(seed(frameID: first, suffix: 30, text: "alpha evidence"))
        _ = try store.publish(seed(frameID: second, suffix: 31, text: "beta evidence"))
        try store.corruptIndexForTesting()
        XCTAssertFalse(try store.integritySnapshot().isConsistent)

        let rebuilt = try store.rebuild()

        XCTAssertEqual(rebuilt.readyFrameCount, 2)
        XCTAssertEqual(rebuilt.readyMergedRecordCount, 2)
        XCTAssertEqual(rebuilt.indexedRowCount, 2)
        XCTAssertTrue(rebuilt.isConsistent)
        XCTAssertEqual(try store.matchingFrameIDsForTesting(query: "alpha"), [first])
        XCTAssertEqual(try store.matchingFrameIDsForTesting(query: "beta"), [second])
    }

    func testSuppressedWrongFrameAndReservedTranscriptInputsFailClosed() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = try archive.insertSearchFrameFixtureForTesting(suffix: 6)
        let otherFrameID = UUID(uuidString: "35000000-0000-0000-0000-000000000999")!
        let store = ArchiveSearchIndexStore(database: archive)
        let suppressed = try textSpan(
            suffix: 40,
            frameID: frameID,
            source: .accessibility,
            text: "SECRET_SENTINEL",
            sensitivity: .suppressed
        )
        XCTAssertThrowsError(
            try store.publish(
                ArchiveMergedTextSeed(
                    frameID: frameID,
                    approvedSpans: [suppressed],
                    transcriptSpans: [],
                    producerVersion: "merged-text-v1"
                )
            )
        )
        XCTAssertThrowsError(
            try store.publish(
                ArchiveMergedTextSeed(
                    frameID: frameID,
                    approvedSpans: [
                        try textSpan(
                            suffix: 41,
                            frameID: otherFrameID,
                            source: .accessibility,
                            text: "wrong frame"
                        )
                    ],
                    transcriptSpans: [],
                    producerVersion: "merged-text-v1"
                )
            )
        )
        let transcript = try textSpan(
            suffix: 42,
            frameID: frameID,
            source: .transcript,
            text: "future transcript"
        )
        XCTAssertThrowsError(
            try store.publish(
                ArchiveMergedTextSeed(
                    frameID: frameID,
                    approvedSpans: [transcript],
                    transcriptSpans: [],
                    producerVersion: "merged-text-v1"
                )
            )
        )
        XCTAssertTrue(try store.matchingFrameIDsForTesting(query: "SECRET").isEmpty)
        XCTAssertEqual(try store.mergedRecordCountForTesting(), 0)
    }
}

private func seed(
    frameID: UUID,
    suffix: Int,
    text: String
) throws -> ArchiveMergedTextSeed {
    try ArchiveMergedTextSeed(
        frameID: frameID,
        approvedSpans: [
            textSpan(
                suffix: suffix,
                frameID: frameID,
                source: .accessibility,
                text: text
            )
        ],
        transcriptSpans: [],
        producerVersion: "merged-text-v1"
    )
}

private func textSpan(
    suffix: Int,
    frameID: UUID,
    source: TextSource,
    text: String,
    sensitivity: TextSensitivity = .normal
) throws -> TextSpan {
    try TextSpan(
        id: UUID(uuidString: String(format: "35000000-0000-0000-0000-%012d", suffix))!,
        frameID: frameID,
        source: source,
        text: text,
        bounds: nil,
        confidence: source == .visionOCR ? 0.9 : nil,
        languageCode: source == .visionOCR ? "en" : nil,
        sensitivity: sensitivity
    )
}
