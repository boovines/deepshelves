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
        let relativePath: String
        let byteCount: Int64
        let sha256: String?
        let state: String
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
                    SELECT id, relative_path, byte_count, sha256, state
                    FROM media_chunks
                    """
            )
            return rows.map { row in
                ChunkRecord(
                    id: row["id"],
                    relativePath: row["relative_path"],
                    byteCount: row["byte_count"],
                    sha256: row["sha256"],
                    state: row["state"]
                )
            }
        }

        let fileStore = ArchiveFileStore(paths: paths, fileManager: fileManager)
        var validReadyPaths: Set<String> = []
        var invalidChunkIDs: Set<String> = []
        var corruptFiles = 0
        var missingReadyFiles = 0

        for chunk in chunks {
            guard let relativePath = try? ArchiveRelativePath(chunk.relativePath),
                  relativePath.rawValue.hasPrefix("media/")
            else {
                invalidChunkIDs.insert(chunk.id)
                continue
            }
            let fileURL = fileStore.url(for: relativePath)
            guard chunk.state == "ready" else {
                invalidChunkIDs.insert(chunk.id)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try quarantine(
                        fileURL,
                        reason: "non-ready",
                        paths: paths,
                        fileManager: fileManager
                    )
                    corruptFiles += 1
                }
                continue
            }
            guard fileManager.fileExists(atPath: fileURL.path) else {
                invalidChunkIDs.insert(chunk.id)
                missingReadyFiles += 1
                continue
            }

            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            let expectedHash = chunk.sha256 ?? ""
            let isValidHash = expectedHash.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
            let actualHash = values.isRegularFile == true && values.isSymbolicLink != true
                ? try ArchiveFileStore.sha256(of: fileURL).hex
                : ""
            let hasValidIntegrity = values.isRegularFile == true &&
                values.isSymbolicLink != true &&
                Int64(values.fileSize ?? -1) == chunk.byteCount &&
                isValidHash &&
                actualHash == expectedHash

            if hasValidIntegrity {
                validReadyPaths.insert(relativePath.rawValue)
            } else {
                invalidChunkIDs.insert(chunk.id)
                try quarantine(
                    fileURL,
                    reason: "integrity",
                    paths: paths,
                    fileManager: fileManager
                )
                corruptFiles += 1
            }
        }

        var orphanFiles = 0
        for mediaURL in try regularMediaFiles(in: paths.media, fileManager: fileManager) {
            let resolvedRoot = paths.root.resolvingSymlinksInPath().path
            let resolvedMedia = mediaURL.resolvingSymlinksInPath().path
            guard resolvedMedia.hasPrefix(resolvedRoot + "/") else {
                continue
            }
            let relativePath = String(resolvedMedia.dropFirst(resolvedRoot.count + 1))
            guard !validReadyPaths.contains(relativePath) else { continue }
            try quarantine(
                mediaURL,
                reason: "orphan",
                paths: paths,
                fileManager: fileManager
            )
            orphanFiles += 1
        }

        var suppressedFrames = 0
        var requeuedJobs = 0
        try writer.write { database in
            for chunkID in invalidChunkIDs.sorted() {
                suppressedFrames += try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM frames
                        WHERE chunk_id = ? AND approved_text <> ''
                        """,
                    arguments: [chunkID]
                ) ?? 0
                try database.execute(
                    sql: """
                        DELETE FROM frame_fts
                        WHERE rowid IN (SELECT rowid FROM frames WHERE chunk_id = ?)
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
            quarantinedOrphanFiles: orphanFiles,
            quarantinedCorruptFiles: corruptFiles,
            missingReadyFiles: missingReadyFiles,
            suppressedSearchableFrames: suppressedFrames,
            requeuedLeasedJobs: requeuedJobs
        )
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
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".partial") {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true || values.isSymbolicLink == true else {
                    continue
                }
                try fileManager.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    private static func regularMediaFiles(
        in root: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "mov" {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isRegularFile == true || values.isSymbolicLink == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func quarantine(
        _ source: URL,
        reason: String,
        paths: ArchivePaths,
        fileManager: FileManager
    ) throws {
        let destination = paths.quarantine.appending(
            path: "\(reason)-\(UUID().uuidString.lowercased())-\(source.lastPathComponent)",
            directoryHint: .notDirectory
        )
        try fileManager.moveItem(at: source, to: destination)
        try fileManager.setAttributes(
            [.posixPermissions: ArchivePathProvider.filePermissions],
            ofItemAtPath: destination.path
        )
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
