import Foundation
import GRDB
import MemoryContracts

public struct ArchiveLexicalCursorTuple: Equatable, Sendable {
    public let score: Double
    public let capturedAt: Date
    public let frameID: UUID

    public init(score: Double, capturedAt: Date, frameID: UUID) {
        self.score = score
        self.capturedAt = capturedAt
        self.frameID = frameID
    }
}

public struct ArchiveLexicalQuery: Equatable, Sendable {
    public let ftsQuery: String?
    public let normalizedQuery: String
    public let interval: DateInterval
    public let policyBundleIDs: Set<String>
    public let policyHosts: Set<String>
    public let requestedBundleIDs: Set<String>
    public let requestedHosts: Set<String>
    public let after: ArchiveLexicalCursorTuple?
    public let limit: Int

    public init(
        ftsQuery: String?,
        normalizedQuery: String,
        interval: DateInterval,
        policyBundleIDs: Set<String>,
        policyHosts: Set<String>,
        requestedBundleIDs: Set<String>,
        requestedHosts: Set<String>,
        after: ArchiveLexicalCursorTuple?,
        limit: Int
    ) {
        self.ftsQuery = ftsQuery
        self.normalizedQuery = normalizedQuery
        self.interval = interval
        self.policyBundleIDs = policyBundleIDs
        self.policyHosts = policyHosts
        self.requestedBundleIDs = requestedBundleIDs
        self.requestedHosts = requestedHosts
        self.after = after
        self.limit = limit
    }
}

public struct ArchiveLexicalCandidate: Equatable, Sendable {
    public let frameID: UUID
    public let capturedAt: Date
    public let bundleIdentifier: String
    public let applicationName: String
    public let windowTitle: String?
    public let windowBounds: NormalizedRect
    public let browserFamily: BrowserFamily?
    public let urlScheme: String?
    public let urlHost: String?
    public let urlPath: String?
    public let mediaPath: String?
    public let thumbnailPath: String?
    public let approvedText: String
    public let transcriptText: String
    public let spans: [TextSpan]
    public let score: Double
    public let textRank: Int
}

extension ArchiveSearchIndexStore {
    public func lexicalCandidates(_ query: ArchiveLexicalQuery) throws
        -> [ArchiveLexicalCandidate]
    {
        guard query.limit > 0, query.limit <= 101, !query.policyBundleIDs.isEmpty else {
            return []
        }
        return try archive.atomicRead { database in
            let rows = try Self.lexicalRows(query, database: database)
            let frameIDs = rows.map { $0["frame_id"] as String }
            let spans = try Self.lexicalSpans(frameIDs: frameIDs, database: database)
            return try rows.map { row in
                try Self.lexicalCandidate(
                    row,
                    spans: spans[row["frame_id"] as String] ?? []
                )
            }
        }
    }

    private static func lexicalRows(_ query: ArchiveLexicalQuery, database: Database) throws
        -> [Row]
    {
        var arguments: [DatabaseValueConvertible?] = []
        let hasLexicalText = query.ftsQuery?.isEmpty == false
        let scoreExpression: String
        if hasLexicalText {
            scoreExpression = """
                (-bm25(frame_fts, 6.0, 4.0, 2.0, 2.0, 1.5, 1.0)
                 + CASE
                     WHEN lower(COALESCE(merged_text_records.window_title, '')) = lower(?)
                     THEN 4.0
                     WHEN instr(lower(COALESCE(merged_text_records.window_title, '')), lower(?)) > 0
                     THEN 1.5 ELSE 0.0 END
                 + CASE WHEN lower(COALESCE(merged_text_records.app_name, '')) = lower(?)
                        THEN 3.0 ELSE 0.0 END
                 + CASE WHEN lower(COALESCE(merged_text_records.url_host, '')) = lower(?)
                        THEN 2.5 ELSE 0.0 END
                 + CASE WHEN lower(COALESCE(merged_text_records.url_path, '')) = lower(?)
                        THEN 1.5 ELSE 0.0 END)
                """
            arguments.append(contentsOf: [
                query.normalizedQuery,
                query.normalizedQuery,
                query.normalizedQuery,
                query.normalizedQuery,
                query.normalizedQuery,
            ])
        } else {
            scoreExpression = "0.0"
        }

        let source =
            hasLexicalText
            ? "frame_fts JOIN merged_text_records ON merged_text_records.rowid = frame_fts.rowid"
            : "merged_text_records"
        var clauses = [
            "merged_text_records.state = 'ready'",
            "frames.text_state = 'ready'",
            "media_chunks.state = 'ready'",
            "frames.bundle_id IS NOT NULL",
            "merged_text_records.app_name IS NOT NULL",
            "frames.window_x IS NOT NULL",
            "frames.window_y IS NOT NULL",
            "frames.window_w IS NOT NULL",
            "frames.window_h IS NOT NULL",
        ]
        if let ftsQuery = query.ftsQuery, hasLexicalText {
            clauses.append("frame_fts MATCH ?")
            arguments.append(ftsQuery)
        }
        clauses.append("frames.captured_at >= ? AND frames.captured_at < ?")
        arguments.append(encode(query.interval.start))
        arguments.append(encode(query.interval.end))

        let policyBundles = query.policyBundleIDs.sorted()
        clauses.append("frames.bundle_id IN (\(placeholders(policyBundles.count)))")
        arguments.append(contentsOf: policyBundles)
        let policyHosts = query.policyHosts.sorted()
        if policyHosts.isEmpty {
            clauses.append("merged_text_records.url_host IS NULL")
        } else {
            clauses.append(
                "(merged_text_records.url_host IS NULL OR merged_text_records.url_host IN (\(placeholders(policyHosts.count))))"
            )
            arguments.append(contentsOf: policyHosts)
        }
        let requestedBundles = query.requestedBundleIDs.sorted()
        if !requestedBundles.isEmpty {
            clauses.append("frames.bundle_id IN (\(placeholders(requestedBundles.count)))")
            arguments.append(contentsOf: requestedBundles)
        }
        let requestedHosts = query.requestedHosts.sorted()
        if !requestedHosts.isEmpty {
            clauses.append(
                "merged_text_records.url_host IN (\(placeholders(requestedHosts.count)))"
            )
            arguments.append(contentsOf: requestedHosts)
        }

        var pageClause = ""
        if let after = query.after {
            pageClause = """
                WHERE final_score < ?
                   OR (final_score = ? AND captured_at < ?)
                   OR (final_score = ? AND captured_at = ? AND frame_id > ?)
                """
            let capturedAt = encode(after.capturedAt)
            let cursorArguments: [DatabaseValueConvertible?] = [
                after.score,
                after.score,
                capturedAt,
                after.score,
                capturedAt,
                after.frameID.uuidString.lowercased(),
            ]
            arguments.append(contentsOf: cursorArguments)
        }
        arguments.append(query.limit)
        let sql = """
            WITH scored AS (
                SELECT frames.id AS frame_id,
                       frames.captured_at,
                       frames.bundle_id,
                       merged_text_records.app_name AS frame_app_name,
                       merged_text_records.window_title AS frame_window_title,
                       frames.window_x, frames.window_y, frames.window_w, frames.window_h,
                       frames.browser_family, frames.url_scheme,
                       merged_text_records.url_host AS frame_url_host,
                       merged_text_records.url_path AS frame_url_path,
                       frames.media_path, frames.thumbnail_path,
                       merged_text_records.approved_text,
                       merged_text_records.transcript_text,
                       merged_text_records.window_title,
                       merged_text_records.app_name,
                       merged_text_records.url_host,
                       merged_text_records.url_path,
                       \(scoreExpression) AS final_score
                FROM \(source)
                JOIN frames ON frames.id = merged_text_records.frame_id
                JOIN media_chunks ON media_chunks.id = frames.chunk_id
                WHERE \(clauses.joined(separator: " AND "))
            ), ranked AS (
                SELECT *, ROW_NUMBER() OVER (
                    ORDER BY final_score DESC, captured_at DESC, frame_id ASC
                ) AS text_rank
                FROM scored
            )
            SELECT * FROM ranked
            \(pageClause)
            ORDER BY final_score DESC, captured_at DESC, frame_id ASC
            LIMIT ?
            """
        return try Row.fetchAll(
            database,
            sql: sql,
            arguments: StatementArguments(arguments)
        )
    }

    private static func lexicalSpans(
        frameIDs: [String],
        database: Database
    ) throws -> [String: [TextSpan]] {
        guard !frameIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, frame_id, source, text, x, y, w, h,
                       confidence, language_code, sensitivity
                FROM text_spans
                WHERE frame_id IN (\(placeholders(frameIDs.count)))
                  AND sensitivity <> 'suppressed'
                ORDER BY frame_id, COALESCE(y, 2), COALESCE(x, 2), id
                """,
            arguments: StatementArguments(frameIDs)
        )
        var result: [String: [TextSpan]] = [:]
        for row in rows {
            let frameIDString: String = row["frame_id"]
            guard let frameID = UUID(uuidString: frameIDString),
                let spanID = UUID(uuidString: row["id"] as String),
                let source = TextSource(rawValue: row["source"] as String),
                let sensitivity = TextSensitivity(rawValue: row["sensitivity"] as String)
            else {
                continue
            }
            let bounds = try lexicalBounds(row)
            let confidence: Double? = row["confidence"]
            let span = try TextSpan(
                id: spanID,
                frameID: frameID,
                source: source,
                text: row["text"],
                bounds: bounds,
                confidence: confidence.map(Float.init),
                languageCode: row["language_code"],
                sensitivity: sensitivity
            )
            result[frameIDString, default: []].append(span)
        }
        return result
    }

    private static func lexicalCandidate(_ row: Row, spans: [TextSpan]) throws
        -> ArchiveLexicalCandidate
    {
        guard let frameID = UUID(uuidString: row["frame_id"] as String),
            let capturedAt = decode(row["captured_at"] as String)
        else {
            throw ArchiveSearchIndexError.invalidApprovedMetadata
        }
        let bounds = try NormalizedRect(
            x: row["window_x"],
            y: row["window_y"],
            width: row["window_w"],
            height: row["window_h"]
        )
        let browserFamilyRaw: String? = row["browser_family"]
        return ArchiveLexicalCandidate(
            frameID: frameID,
            capturedAt: capturedAt,
            bundleIdentifier: row["bundle_id"],
            applicationName: row["frame_app_name"],
            windowTitle: row["frame_window_title"],
            windowBounds: bounds,
            browserFamily: browserFamilyRaw.flatMap(BrowserFamily.init(rawValue:)),
            urlScheme: row["url_scheme"],
            urlHost: row["frame_url_host"],
            urlPath: row["frame_url_path"],
            mediaPath: row["media_path"],
            thumbnailPath: row["thumbnail_path"],
            approvedText: row["approved_text"],
            transcriptText: row["transcript_text"],
            spans: spans,
            score: row["final_score"],
            textRank: row["text_rank"]
        )
    }

    private static func lexicalBounds(_ row: Row) throws -> NormalizedRect? {
        let x: Double? = row["x"]
        let y: Double? = row["y"]
        let width: Double? = row["w"]
        let height: Double? = row["h"]
        guard let x, let y, let width, let height else { return nil }
        return try NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }

    private static func decode(_ value: String) -> Date? {
        try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }
}
