import Foundation
import GRDB

public struct ArchiveStartupRecoveryReport: Codable, Equatable, Sendable {
    public let removedPartialFiles: Int
    public let quarantinedOrphanFiles: Int
    public let quarantinedCorruptFiles: Int
    public let missingReadyFiles: Int
    public let suppressedSearchableFrames: Int
    public let requeuedLeasedJobs: Int

    public static let empty = ArchiveStartupRecoveryReport(
        removedPartialFiles: 0,
        quarantinedOrphanFiles: 0,
        quarantinedCorruptFiles: 0,
        missingReadyFiles: 0,
        suppressedSearchableFrames: 0,
        requeuedLeasedJobs: 0
    )
}

enum ArchiveStartupRecovery {
    private struct ChunkRecord: Sendable {
        let id: String
        let captureEpochID: String
        let targetWindowID: UInt32
        let relativePath: String
        let codec: String
        let frameCount: Int
        let byteCount: Int64
        let sha256: String?
        let state: String
    }

    private struct V2FrameRecord: Sendable {
        let id: String
        let captureEpochID: String
        let targetWindowID: UInt32
        let presentationTimeMilliseconds: Int64
        let mediaPath: String?
        let mediaSHA256: String?
        let mediaByteCount: Int64?
        let policyGeneration: Int64?
        let schemaVersion: Int
    }

    static func recover(
        paths: ArchivePaths,
        writer: any DatabaseWriter,
        fileManager: FileManager
    ) throws -> ArchiveStartupRecoveryReport {
        let removedPartials = try removeOrphanPartials(paths: paths, fileManager: fileManager)
        let chunks = try writer.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, capture_epoch_id, target_window_id, relative_path,
                           codec, frame_count, byte_count, sha256, state
                    FROM media_chunks
                    ORDER BY id
                    """
            )
            return rows.map { row in
                ChunkRecord(
                    id: row["id"],
                    captureEpochID: row["capture_epoch_id"],
                    targetWindowID: UInt32(row["target_window_id"] as Int64),
                    relativePath: row["relative_path"],
                    codec: row["codec"],
                    frameCount: row["frame_count"],
                    byteCount: row["byte_count"],
                    sha256: row["sha256"],
                    state: row["state"]
                )
            }
        }

        let fileStore = ArchiveFileStore(paths: paths, fileManager: fileManager)
        var validReadyPaths: Set<String> = []
        var invalidChunkIDs: Set<String> = []
        var corruptItems = 0
        var missingReadyItems = 0

        for chunk in chunks {
            guard let relativePath = try? ArchiveRelativePath(chunk.relativePath),
                relativePath.rawValue.hasPrefix("media/")
            else {
                invalidChunkIDs.insert(chunk.id)
                continue
            }
            let manifestOrFileURL = fileStore.url(for: relativePath)
            let mediaItemURL =
                chunk.codec == "heicKeyframes"
                ? manifestOrFileURL.deletingLastPathComponent()
                : manifestOrFileURL
            guard chunk.state == "ready" else {
                invalidChunkIDs.insert(chunk.id)
                if fileManager.fileExists(atPath: mediaItemURL.path) {
                    try quarantine(
                        mediaItemURL,
                        reason: "non-ready",
                        paths: paths,
                        fileManager: fileManager
                    )
                    corruptItems += 1
                }
                continue
            }
            guard fileManager.fileExists(atPath: manifestOrFileURL.path) else {
                invalidChunkIDs.insert(chunk.id)
                missingReadyItems += 1
                continue
            }

            let isValid: Bool
            if chunk.codec == "heicKeyframes" {
                isValid = try verifyHEIC(
                    chunk,
                    relativePath: relativePath,
                    paths: paths,
                    writer: writer,
                    fileManager: fileManager
                )
            } else if chunk.codec == "hevcMain" || chunk.codec == "hevc",
                relativePath.rawValue.hasSuffix(".mov")
            {
                isValid = try verifyLegacyFile(
                    chunk,
                    at: manifestOrFileURL
                )
            } else {
                isValid = false
            }

            if isValid {
                validReadyPaths.insert(relativePath.rawValue)
            } else {
                invalidChunkIDs.insert(chunk.id)
                if fileManager.fileExists(atPath: mediaItemURL.path) {
                    try quarantine(
                        mediaItemURL,
                        reason: "integrity",
                        paths: paths,
                        fileManager: fileManager
                    )
                    corruptItems += 1
                }
            }
        }

        var orphanItems = 0
        for mediaURL in try publishedMediaItems(in: paths.media, fileManager: fileManager) {
            let resolvedRoot = paths.root.resolvingSymlinksInPath().path
            let resolvedMedia = mediaURL.resolvingSymlinksInPath().path
            guard resolvedMedia.hasPrefix(resolvedRoot + "/") else { continue }
            let itemValues = try mediaURL.resourceValues(forKeys: [.isDirectoryKey])
            let relativeItemPath = String(resolvedMedia.dropFirst(resolvedRoot.count + 1))
            let databasePath =
                itemValues.isDirectory == true
                ? relativeItemPath + "/manifest.json"
                : relativeItemPath
            guard !validReadyPaths.contains(databasePath) else { continue }
            try quarantine(
                mediaURL,
                reason: "orphan",
                paths: paths,
                fileManager: fileManager
            )
            orphanItems += 1
        }

        var suppressedFrames = 0
        var requeuedJobs = 0
        try writer.write { database in
            for chunkID in invalidChunkIDs.sorted() {
                suppressedFrames +=
                    try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*) FROM frames
                            WHERE chunk_id = ? AND approved_text <> ''
                            """,
                        arguments: [chunkID]
                    ) ?? 0
                try database.execute(
                    sql: """
                        INSERT INTO frame_fts(
                            frame_fts, rowid, approved_text, window_title,
                            app_name, url_host, url_path, transcript_text
                        )
                        SELECT 'delete', merged_text_records.rowid,
                               merged_text_records.approved_text,
                               merged_text_records.window_title,
                               merged_text_records.app_name,
                               merged_text_records.url_host,
                               merged_text_records.url_path,
                               merged_text_records.transcript_text
                        FROM merged_text_records
                        JOIN frames ON frames.id = merged_text_records.frame_id
                        WHERE frames.chunk_id = ? AND merged_text_records.state = 'ready'
                        """,
                    arguments: [chunkID]
                )
                try database.execute(
                    sql: """
                        UPDATE merged_text_records
                        SET approved_text = '', transcript_text = '',
                            window_title = NULL, app_name = NULL,
                            url_host = NULL, url_path = NULL, state = 'suppressed'
                        WHERE frame_id IN (SELECT id FROM frames WHERE chunk_id = ?)
                        """,
                    arguments: [chunkID]
                )
                try database.execute(
                    sql: """
                        UPDATE frames
                        SET approved_text = '',
                            text_state = 'suppressed',
                            visual_state = 'suppressed'
                        WHERE chunk_id = ?
                        """,
                    arguments: [chunkID]
                )
                try database.execute(
                    sql: """
                        UPDATE artifacts
                        SET state = 'failed'
                        WHERE frame_id IN (SELECT id FROM frames WHERE chunk_id = ?)
                        """,
                    arguments: [chunkID]
                )
                try database.execute(
                    sql: """
                        UPDATE processing_jobs
                        SET state = 'cancelled', lease_expires_at = NULL,
                            error_code = 'parent_media_quarantined'
                        WHERE parent_id = ?
                           OR parent_id IN (SELECT id FROM frames WHERE chunk_id = ?)
                        """,
                    arguments: [chunkID, chunkID]
                )
                try database.execute(
                    sql: "UPDATE media_chunks SET state = 'quarantined' WHERE id = ?",
                    arguments: [chunkID]
                )
            }
            try database.execute(
                sql: """
                    UPDATE processing_jobs
                    SET state = 'queued', lease_expires_at = NULL,
                        next_attempt_at = NULL, error_code = 'recovered_after_restart'
                    WHERE state = 'leased'
                    """
            )
            requeuedJobs = database.changesCount
        }

        try ArchivePathProvider.enforceOwnerOnlyTree(at: paths.root, fileManager: fileManager)
        return ArchiveStartupRecoveryReport(
            removedPartialFiles: removedPartials,
            quarantinedOrphanFiles: orphanItems,
            quarantinedCorruptFiles: corruptItems,
            missingReadyFiles: missingReadyItems,
            suppressedSearchableFrames: suppressedFrames,
            requeuedLeasedJobs: requeuedJobs
        )
    }

    private static func verifyHEIC(
        _ chunk: ChunkRecord,
        relativePath: ArchiveRelativePath,
        paths: ArchivePaths,
        writer: any DatabaseWriter,
        fileManager: FileManager
    ) throws -> Bool {
        guard let chunkID = UUID(uuidString: chunk.id),
            let captureEpochID = UUID(uuidString: chunk.captureEpochID)
        else {
            return false
        }
        let verified: ArchiveVerifiedHEICChunk
        do {
            verified = try ArchiveHEICChunkVerifier.verify(
                paths: paths,
                manifestRelativePath: relativePath,
                expectedChunkID: chunkID,
                expectedCaptureEpochID: captureEpochID,
                expectedTargetWindowID: chunk.targetWindowID,
                fileManager: fileManager
            )
        } catch {
            return false
        }
        guard chunk.frameCount == verified.frames.count,
            chunk.byteCount == verified.totalByteCount,
            chunk.sha256 == verified.manifestSHA256.hex
        else {
            return false
        }
        let databaseFrames = try writer.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, capture_epoch_id, target_window_id, pts_ms,
                           media_path, media_sha256, media_byte_count,
                           policy_generation, schema_version
                    FROM frames
                    WHERE chunk_id = ?
                    ORDER BY pts_ms, id
                    """,
                arguments: [chunk.id]
            )
            return rows.map { row in
                V2FrameRecord(
                    id: row["id"],
                    captureEpochID: row["capture_epoch_id"],
                    targetWindowID: UInt32(row["target_window_id"] as Int64),
                    presentationTimeMilliseconds: row["pts_ms"],
                    mediaPath: row["media_path"],
                    mediaSHA256: row["media_sha256"],
                    mediaByteCount: row["media_byte_count"],
                    policyGeneration: row["policy_generation"],
                    schemaVersion: row["schema_version"]
                )
            }
        }
        guard databaseFrames.count == verified.frames.count else { return false }
        return zip(databaseFrames, verified.frames).allSatisfy { databaseFrame, sourceFrame in
            databaseFrame.id == sourceFrame.id.uuidString.lowercased()
                && databaseFrame.captureEpochID == chunk.captureEpochID
                && databaseFrame.targetWindowID == chunk.targetWindowID
                && databaseFrame.presentationTimeMilliseconds
                    == sourceFrame.presentationTimeMilliseconds
                && databaseFrame.mediaPath == sourceFrame.archiveRelativePath
                && databaseFrame.mediaSHA256 == sourceFrame.sha256.hex
                && databaseFrame.mediaByteCount == sourceFrame.byteCount
                && (databaseFrame.policyGeneration ?? 0) > 0
                && databaseFrame.schemaVersion >= 2
        }
    }

    private static func verifyLegacyFile(_ chunk: ChunkRecord, at fileURL: URL) throws -> Bool {
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        let expectedHash = chunk.sha256 ?? ""
        let isValidHash =
            expectedHash.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        let actualHash =
            values.isRegularFile == true && values.isSymbolicLink != true
            ? try ArchiveFileStore.sha256(of: fileURL).hex
            : ""
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && Int64(values.fileSize ?? -1) == chunk.byteCount
            && isValidHash
            && actualHash == expectedHash
    }

    private static func removeOrphanPartials(
        paths: ArchivePaths,
        fileManager: FileManager
    ) throws -> Int {
        let roots = [
            paths.media,
            paths.thumbnails,
            paths.vectors,
            paths.models,
            paths.exports,
            paths.logs,
        ]
        var removed = 0
        for root in roots {
            guard
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    ]
                )
            else { continue }
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".partial")
            {
                let values = try url.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard
                    values.isDirectory == true || values.isRegularFile == true
                        || values.isSymbolicLink == true
                else { continue }
                if values.isDirectory == true { enumerator.skipDescendants() }
                try fileManager.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    private static func publishedMediaItems(
        in root: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ]
            )
        else { return [] }
        var items: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isDirectory == true,
                UUID(uuidString: url.lastPathComponent) != nil
            {
                items.append(url)
                enumerator.skipDescendants()
            } else if values.isRegularFile == true && url.pathExtension == "mov" {
                items.append(url)
            } else if values.isSymbolicLink == true {
                items.append(url)
                enumerator.skipDescendants()
            }
        }
        return items.sorted { $0.path < $1.path }
    }

    private static func quarantine(
        _ source: URL,
        reason: String,
        paths: ArchivePaths,
        fileManager: FileManager
    ) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        let destination = paths.quarantine.appending(
            path: "\(reason)-\(UUID().uuidString.lowercased())-\(source.lastPathComponent)",
            directoryHint: values.isDirectory == true ? .isDirectory : .notDirectory
        )
        try fileManager.moveItem(at: source, to: destination)
        if values.isDirectory == true {
            try ArchivePathProvider.enforceOwnerOnlyTree(at: destination, fileManager: fileManager)
        } else {
            try fileManager.setAttributes(
                [.posixPermissions: ArchivePathProvider.filePermissions],
                ofItemAtPath: destination.path
            )
        }
    }
}

extension Data {
    fileprivate var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
