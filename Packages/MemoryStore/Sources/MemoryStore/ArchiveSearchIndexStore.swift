import Foundation
import GRDB
import MemoryContracts

public enum ArchiveSearchIndexError: Error, Equatable, Sendable {
    case missingFrame
    case parentMediaNotReady
    case invalidProducerVersion
    case invalidSpanFrame
    case invalidSpanSource
    case suppressedSpan
    case duplicateSpanIdentifier
    case mergedTextTooLarge
    case invalidApprovedMetadata
}

public struct ArchiveMergedTextSeed: Equatable, Sendable {
    public let frameID: UUID
    public let approvedSpans: [TextSpan]
    public let transcriptSpans: [TextSpan]
    public let producerVersion: String

    public init(
        frameID: UUID,
        approvedSpans: [TextSpan],
        transcriptSpans: [TextSpan],
        producerVersion: String
    ) throws {
        self.frameID = frameID
        self.approvedSpans = approvedSpans
        self.transcriptSpans = transcriptSpans
        self.producerVersion = producerVersion
        try Self.validate(
            frameID: frameID,
            approvedSpans: approvedSpans,
            transcriptSpans: transcriptSpans,
            producerVersion: producerVersion
        )
    }

    private static func validate(
        frameID: UUID,
        approvedSpans: [TextSpan],
        transcriptSpans: [TextSpan],
        producerVersion: String
    ) throws {
        guard !producerVersion.isEmpty, producerVersion.count <= 128,
            producerVersion.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
            })
        else {
            throw ArchiveSearchIndexError.invalidProducerVersion
        }
        let allSpans = approvedSpans + transcriptSpans
        guard Set(allSpans.map(\.id)).count == allSpans.count else {
            throw ArchiveSearchIndexError.duplicateSpanIdentifier
        }
        for span in allSpans {
            try span.validate()
            guard span.frameID == frameID else {
                throw ArchiveSearchIndexError.invalidSpanFrame
            }
            guard span.sensitivity != .suppressed else {
                throw ArchiveSearchIndexError.suppressedSpan
            }
        }
        guard
            approvedSpans.allSatisfy({
                $0.source == .accessibility || $0.source == .visionOCR
            }), transcriptSpans.allSatisfy({ $0.source == .transcript })
        else {
            throw ArchiveSearchIndexError.invalidSpanSource
        }
        let mergedByteCount = (approvedSpans + transcriptSpans)
            .reduce(0) { $0 + $1.text.utf8.count }
        guard mergedByteCount <= ArchiveSearchIndexStore.maximumMergedTextBytes else {
            throw ArchiveSearchIndexError.mergedTextTooLarge
        }
    }
}

public struct ArchiveMergedTextRecord: Equatable, Sendable {
    public let rowID: Int64
    public let frameID: UUID
    public let approvedText: String
    public let transcriptText: String
    public let windowTitle: String?
    public let applicationName: String?
    public let urlHost: String?
    public let urlPath: String?
    public let producerVersion: String
}

public struct ArchiveSearchIndexIntegrity: Equatable, Sendable {
    public let readyFrameCount: Int
    public let readyMergedRecordCount: Int
    public let indexedRowCount: Int
    public let missingMergedRecordCount: Int
    public let missingIndexRowCount: Int
    public let unexpectedIndexRowCount: Int

    public var isConsistent: Bool {
        readyFrameCount == readyMergedRecordCount
            && readyMergedRecordCount == indexedRowCount
            && missingMergedRecordCount == 0
            && missingIndexRowCount == 0
            && unexpectedIndexRowCount == 0
    }
}

public final class ArchiveSearchIndexStore: @unchecked Sendable {
    public static let maximumMergedTextBytes = 1_048_576

    private let archive: ArchiveDatabase

    public init(database: ArchiveDatabase) {
        archive = database
    }

    @discardableResult
    public func publish(_ seed: ArchiveMergedTextSeed) throws -> ArchiveMergedTextRecord {
        try archive.atomicWrite { database in
            let frameID = seed.frameID.uuidString.lowercased()
            guard
                let frame = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT frames.rowid, frames.window_title, frames.app_name,
                               frames.url_host, frames.url_path, media_chunks.state AS chunk_state
                        FROM frames
                        JOIN media_chunks ON media_chunks.id = frames.chunk_id
                        WHERE frames.id = ?
                        """,
                    arguments: [frameID]
                )
            else {
                throw ArchiveSearchIndexError.missingFrame
            }
            guard (frame["chunk_state"] as String) == "ready" else {
                throw ArchiveSearchIndexError.parentMediaNotReady
            }
            let metadata = try Self.approvedMetadata(from: frame)
            let approvedText = seed.approvedSpans.map(\.text).joined(separator: "\n")
            let transcriptText = seed.transcriptSpans.map(\.text).joined(separator: "\n")
            let oldRecord = try Self.recordRow(frameID: frameID, database: database)
            if let oldRecord {
                try Self.deleteFTSRow(oldRecord, database: database)
            }

            try database.execute(
                sql: "DELETE FROM text_spans WHERE frame_id = ?",
                arguments: [frameID]
            )
            for span in seed.approvedSpans + seed.transcriptSpans {
                try Self.insert(span: span, database: database)
            }

            if oldRecord == nil {
                try database.execute(
                    sql: """
                        INSERT INTO merged_text_records(
                            frame_id, approved_text, transcript_text, window_title,
                            app_name, url_host, url_path, producer_version, state
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ready')
                        """,
                    arguments: [
                        frameID,
                        approvedText,
                        transcriptText,
                        metadata.windowTitle,
                        metadata.applicationName,
                        metadata.host,
                        metadata.path,
                        seed.producerVersion,
                    ]
                )
            } else {
                try database.execute(
                    sql: """
                        UPDATE merged_text_records
                        SET approved_text = ?, transcript_text = ?, window_title = ?,
                            app_name = ?, url_host = ?, url_path = ?,
                            producer_version = ?, state = 'ready'
                        WHERE frame_id = ?
                        """,
                    arguments: [
                        approvedText,
                        transcriptText,
                        metadata.windowTitle,
                        metadata.applicationName,
                        metadata.host,
                        metadata.path,
                        seed.producerVersion,
                        frameID,
                    ]
                )
            }
            try database.execute(
                sql: """
                    UPDATE frames
                    SET approved_text = ?, text_state = 'ready'
                    WHERE id = ?
                    """,
                arguments: [approvedText, frameID]
            )
            guard let record = try Self.recordRow(frameID: frameID, database: database) else {
                throw ArchiveSearchIndexError.missingFrame
            }
            try Self.insertFTSRow(record, database: database)
            return try Self.record(from: record)
        }
    }

    public func deleteFrameAndSearchEvidence(frameID: UUID) throws {
        try archive.atomicWrite { database in
            let identifier = frameID.uuidString.lowercased()
            if let record = try Self.recordRow(frameID: identifier, database: database) {
                try Self.deleteFTSRow(record, database: database)
            }
            try database.execute(sql: "DELETE FROM frames WHERE id = ?", arguments: [identifier])
        }
    }

    @discardableResult
    public func rebuild() throws -> ArchiveSearchIndexIntegrity {
        try archive.atomicWrite { database in
            try database.execute(sql: "INSERT INTO frame_fts(frame_fts) VALUES('delete-all')")
            try database.execute(
                sql: """
                    INSERT INTO frame_fts(
                        rowid, approved_text, window_title, app_name,
                        url_host, url_path, transcript_text
                    )
                    SELECT merged_text_records.rowid,
                           merged_text_records.approved_text,
                           merged_text_records.window_title,
                           merged_text_records.app_name,
                           merged_text_records.url_host,
                           merged_text_records.url_path,
                           merged_text_records.transcript_text
                    FROM merged_text_records
                    JOIN frames ON frames.id = merged_text_records.frame_id
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    WHERE merged_text_records.state = 'ready'
                      AND frames.text_state = 'ready'
                      AND media_chunks.state = 'ready'
                    ORDER BY merged_text_records.rowid
                    """
            )
            return try Self.integritySnapshot(database: database)
        }
    }

    public func integritySnapshot() throws -> ArchiveSearchIndexIntegrity {
        try archive.atomicRead(Self.integritySnapshot(database:))
    }

    func matchingFrameIDsForTesting(query: String) throws -> [UUID] {
        try archive.atomicRead { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT merged_text_records.frame_id
                    FROM frame_fts
                    JOIN merged_text_records ON merged_text_records.rowid = frame_fts.rowid
                    WHERE frame_fts MATCH ?
                    ORDER BY merged_text_records.frame_id
                    """,
                arguments: [query]
            ).compactMap { row in
                UUID(uuidString: row["frame_id"] as String)
            }
        }
    }

    func mergedRecordCountForTesting() throws -> Int {
        try archive.atomicRead { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM merged_text_records") ?? 0
        }
    }

    func textSpanCountForTesting(frameID: UUID) throws -> Int {
        try archive.atomicRead { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM text_spans WHERE frame_id = ?",
                arguments: [frameID.uuidString.lowercased()]
            ) ?? 0
        }
    }

    func frameExistsForTesting(frameID: UUID) throws -> Bool {
        try archive.atomicRead { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM frames WHERE id = ?)",
                arguments: [frameID.uuidString.lowercased()]
            ) ?? false
        }
    }

    func corruptIndexForTesting() throws {
        try archive.atomicWrite { database in
            if let record = try Row.fetchOne(
                database,
                sql: "SELECT rowid, * FROM merged_text_records ORDER BY rowid LIMIT 1"
            ) {
                try Self.deleteFTSRow(record, database: database)
            }
        }
    }

    private static func integritySnapshot(database: Database) throws
        -> ArchiveSearchIndexIntegrity
    {
        let readyFrameRowIDs = Set(
            try Int64.fetchAll(
                database,
                sql: """
                    SELECT merged_text_records.rowid
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    LEFT JOIN merged_text_records
                      ON merged_text_records.frame_id = frames.id
                     AND merged_text_records.state = 'ready'
                    WHERE frames.text_state = 'ready'
                      AND media_chunks.state = 'ready'
                      AND merged_text_records.rowid IS NOT NULL
                    """
            )
        )
        let readyFrameCount =
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    WHERE frames.text_state = 'ready' AND media_chunks.state = 'ready'
                    """
            ) ?? 0
        let readyMergedRecordCount = readyFrameRowIDs.count
        let indexedRowIDs = Set(
            try Int64.fetchAll(database, sql: "SELECT id FROM frame_fts_docsize")
        )
        return ArchiveSearchIndexIntegrity(
            readyFrameCount: readyFrameCount,
            readyMergedRecordCount: readyMergedRecordCount,
            indexedRowCount: indexedRowIDs.count,
            missingMergedRecordCount: max(0, readyFrameCount - readyMergedRecordCount),
            missingIndexRowCount: readyFrameRowIDs.subtracting(indexedRowIDs).count,
            unexpectedIndexRowCount: indexedRowIDs.subtracting(readyFrameRowIDs).count
        )
    }

    private static func recordRow(frameID: String, database: Database) throws -> Row? {
        try Row.fetchOne(
            database,
            sql: "SELECT rowid, * FROM merged_text_records WHERE frame_id = ?",
            arguments: [frameID]
        )
    }

    private static func record(from row: Row) throws -> ArchiveMergedTextRecord {
        guard let frameID = UUID(uuidString: row["frame_id"] as String) else {
            throw ArchiveSearchIndexError.missingFrame
        }
        return ArchiveMergedTextRecord(
            rowID: row["rowid"],
            frameID: frameID,
            approvedText: row["approved_text"],
            transcriptText: row["transcript_text"],
            windowTitle: row["window_title"],
            applicationName: row["app_name"],
            urlHost: row["url_host"],
            urlPath: row["url_path"],
            producerVersion: row["producer_version"]
        )
    }

    private static func insertFTSRow(_ row: Row, database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO frame_fts(
                    rowid, approved_text, window_title, app_name,
                    url_host, url_path, transcript_text
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ftsArguments(row)
        )
    }

    private static func deleteFTSRow(_ row: Row, database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO frame_fts(
                    frame_fts, rowid, approved_text, window_title, app_name,
                    url_host, url_path, transcript_text
                ) VALUES ('delete', ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ftsArguments(row)
        )
    }

    private static func ftsArguments(_ row: Row) -> StatementArguments {
        [
            row["rowid"] as Int64,
            row["approved_text"] as String,
            row["window_title"] as String?,
            row["app_name"] as String?,
            row["url_host"] as String?,
            row["url_path"] as String?,
            row["transcript_text"] as String,
        ]
    }

    private static func insert(span: TextSpan, database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO text_spans(
                    id, frame_id, source, text, x, y, w, h,
                    confidence, language_code, sensitivity
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                span.id.uuidString.lowercased(),
                span.frameID.uuidString.lowercased(),
                span.source.rawValue,
                span.text,
                span.bounds?.x,
                span.bounds?.y,
                span.bounds?.width,
                span.bounds?.height,
                span.confidence,
                span.languageCode,
                span.sensitivity.rawValue,
            ]
        )
    }

    private static func approvedMetadata(from row: Row) throws -> (
        windowTitle: String?, applicationName: String?, host: String?, path: String?
    ) {
        let title: String? = row["window_title"]
        let app: String? = row["app_name"]
        let host: String? = row["url_host"]
        let path: String? = row["url_path"]
        guard normalizedOptional(title), normalizedOptional(app), validHost(host), validPath(path)
        else {
            throw ArchiveSearchIndexError.invalidApprovedMetadata
        }
        return (title, app, host, path)
    }

    private static func normalizedOptional(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value == TextSpan.normalize(value)
    }

    private static func validHost(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value == value.lowercased()
            && !value.contains(where: { $0.isWhitespace || "/?#@".contains($0) })
    }

    private static func validPath(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.hasPrefix("/") && !value.contains("?") && !value.contains("#")
            && !value.contains("..") && value == TextSpan.normalize(value)
    }
}
