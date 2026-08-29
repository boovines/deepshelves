import CryptoKit
import Darwin
import Foundation
import GRDB

public enum ArchiveMaintenanceError: Error, Equatable, Sendable {
    case fileBackedArchiveRequired
    case invalidScope
    case confirmationRequired
    case policyDenied
    case sourceUnavailable
    case destinationExists
    case symbolicLinkForbidden
}

public struct ArchiveExportScope: Equatable, Sendable {
    public let selectedFrameIDs: [UUID]
    public let allowedInterval: DateInterval
    public let allowedBundleIdentifiers: Set<String>
    public let allowedHosts: Set<String>
    public let includeOriginalEvidence: Bool
    public let confirmedByUser: Bool

    public init(
        selectedFrameIDs: [UUID],
        allowedInterval: DateInterval,
        allowedBundleIdentifiers: Set<String>,
        allowedHosts: Set<String>,
        includeOriginalEvidence: Bool,
        confirmedByUser: Bool
    ) throws {
        guard !selectedFrameIDs.isEmpty,
            selectedFrameIDs.count <= 1_000,
            Set(selectedFrameIDs).count == selectedFrameIDs.count,
            allowedInterval.duration > 0,
            allowedBundleIdentifiers.allSatisfy({ !$0.isEmpty }),
            allowedHosts.allSatisfy({
                !$0.isEmpty && $0 == $0.lowercased() && !$0.contains("@")
            })
        else { throw ArchiveMaintenanceError.invalidScope }
        self.selectedFrameIDs = selectedFrameIDs
        self.allowedInterval = allowedInterval
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.allowedHosts = allowedHosts
        self.includeOriginalEvidence = includeOriginalEvidence
        self.confirmedByUser = confirmedByUser
    }
}

public struct ArchiveExportFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String
    public let kind: String
}

public struct ArchiveExportEntry: Codable, Equatable, Sendable {
    public let frameID: UUID
    public let capturedAt: Date
    public let bundleIdentifier: String
    public let host: String?
    public let evidenceRelativePath: String?
}

public struct ArchiveExportManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportID: UUID
    public let createdAt: Date
    public let selectionKind: String
    public let allowedInterval: DateInterval
    public let allowedBundleIdentifiers: [String]
    public let allowedHosts: [String]
    public let entries: [ArchiveExportEntry]
    public let files: [ArchiveExportFile]
}

public struct ArchiveExportReceipt: Equatable, Sendable {
    public let root: URL
    public let manifest: ArchiveExportManifest

    public var exportedFrameCount: Int { manifest.entries.count }
}

public struct ArchiveIntegrityIssue: Codable, Equatable, Sendable {
    public let code: String
    public let identity: String?
}

public struct ArchiveIntegrityReport: Codable, Equatable, Sendable {
    public let cipherIntegrityPassed: Bool
    public let foreignKeyViolationCount: Int
    public let checkedReadyChunkCount: Int
    public let issues: [ArchiveIntegrityIssue]

    public var passed: Bool {
        cipherIntegrityPassed && foreignKeyViolationCount == 0 && issues.isEmpty
    }
}

public struct ArchiveQuarantineItem: Codable, Equatable, Sendable {
    public let relativePath: String
    public let reason: String
    public let byteCount: Int
    public let sha256: String
    public let isDirectory: Bool
}

public struct ArchiveRepairReport: Equatable, Sendable {
    public let recovery: ArchiveStartupRecoveryReport
    public let postRepairIntegrity: ArchiveIntegrityReport
    public let quarantine: [ArchiveQuarantineItem]
}

public final class ArchiveMaintenanceCoordinator: @unchecked Sendable {
    private struct ExportRecord: Sendable {
        let frameID: UUID
        let capturedAt: Date
        let bundleIdentifier: String
        let applicationName: String?
        let windowTitle: String?
        let host: String?
        let path: String?
        let approvedText: String
        let transcriptText: String
        let source: ArchiveMomentSourceRecord
    }

    private struct ExportMetadata: Codable {
        let frameID: UUID
        let capturedAt: Date
        let bundleIdentifier: String
        let applicationName: String?
        let windowTitle: String?
        let host: String?
        let path: String?
        let approvedText: String
        let transcriptText: String
        let originalEvidenceRelativePath: String?
    }

    private struct ReadyChunk: Sendable {
        let id: UUID
        let manifestPath: ArchiveRelativePath
        let captureEpochID: UUID
        let targetWindowID: UInt32
    }

    private struct ReadyChunkCandidate: Sendable {
        let identity: String
        let chunk: ReadyChunk?
    }

    private let database: ArchiveDatabase
    private let paths: ArchivePaths
    private let fileManager: FileManager

    public init(database: ArchiveDatabase, fileManager: FileManager = .default) throws {
        guard let paths = database.paths else {
            throw ArchiveMaintenanceError.fileBackedArchiveRequired
        }
        self.database = database
        self.paths = paths
        self.fileManager = fileManager
    }

    public func export(
        scope: ArchiveExportScope,
        exportID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> ArchiveExportReceipt {
        guard scope.confirmedByUser else { throw ArchiveMaintenanceError.confirmationRequired }
        let records = try scope.selectedFrameIDs.map { try exportRecord(frameID: $0) }
        guard records.allSatisfy({ isAllowed($0, by: scope) }) else {
            throw ArchiveMaintenanceError.policyDenied
        }

        let final = paths.exports.appendingPathComponent(
            exportID.uuidString.lowercased(),
            isDirectory: true
        )
        let staging = paths.exports.appendingPathComponent(
            ".\(exportID.uuidString.lowercased()).partial",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: final.path),
            !fileManager.fileExists(atPath: staging.path)
        else { throw ArchiveMaintenanceError.destinationExists }

        do {
            try ArchivePathProvider.createOwnerOnlyDirectory(
                at: staging,
                beneath: paths.root,
                fileManager: fileManager
            )
            var entries: [ArchiveExportEntry] = []
            var files: [ArchiveExportFile] = []
            var metadataRows: [Data] = []
            for record in records {
                let evidencePath: String?
                if scope.includeOriginalEvidence {
                    let relative = Self.exportEvidencePath(record)
                    let destination = staging.appendingPathComponent(relative)
                    let source = paths.root.appendingPathComponent(record.source.mediaPath.rawValue)
                    let bytes = try verifiedSourceBytes(record, at: source)
                    try write(bytes, to: destination)
                    evidencePath = relative
                    files.append(
                        ArchiveExportFile(
                            relativePath: relative,
                            byteCount: bytes.count,
                            sha256: Self.hex(SHA256.hash(data: bytes)),
                            kind: "originalEvidence"
                        )
                    )
                } else {
                    evidencePath = nil
                }
                let metadata = ExportMetadata(
                    frameID: record.frameID,
                    capturedAt: record.capturedAt,
                    bundleIdentifier: record.bundleIdentifier,
                    applicationName: record.applicationName,
                    windowTitle: record.windowTitle,
                    host: record.host,
                    path: record.path,
                    approvedText: record.approvedText,
                    transcriptText: record.transcriptText,
                    originalEvidenceRelativePath: evidencePath
                )
                metadataRows.append(try JSONEncoder.archiveMaintenance.encode(metadata))
                entries.append(
                    ArchiveExportEntry(
                        frameID: record.frameID,
                        capturedAt: record.capturedAt,
                        bundleIdentifier: record.bundleIdentifier,
                        host: record.host,
                        evidenceRelativePath: evidencePath
                    )
                )
            }
            let metadataData = metadataRows.reduce(into: Data()) { output, row in
                output.append(row)
                output.append(0x0A)
            }
            let metadataPath = "metadata.jsonl"
            try write(metadataData, to: staging.appendingPathComponent(metadataPath))
            files.insert(
                ArchiveExportFile(
                    relativePath: metadataPath,
                    byteCount: metadataData.count,
                    sha256: Self.hex(SHA256.hash(data: metadataData)),
                    kind: "metadataJSONL"
                ),
                at: 0
            )
            let manifest = ArchiveExportManifest(
                schemaVersion: ArchiveExportManifest.currentSchemaVersion,
                exportID: exportID,
                createdAt: createdAt,
                selectionKind: "explicitFrames",
                allowedInterval: scope.allowedInterval,
                allowedBundleIdentifiers: scope.allowedBundleIdentifiers.sorted(),
                allowedHosts: scope.allowedHosts.sorted(),
                entries: entries,
                files: files
            )
            try write(
                JSONEncoder.archiveMaintenance.encode(manifest),
                to: staging.appendingPathComponent("manifest.json")
            )
            try synchronizeDirectory(staging)
            try database.atomicWrite { database in
                guard try records.allSatisfy({ try isCurrent($0, database: database) }) else {
                    throw ArchiveMaintenanceError.sourceUnavailable
                }
                try fileManager.moveItem(at: staging, to: final)
                try synchronizeDirectory(paths.exports)
            }
            try ArchivePathProvider.enforceOwnerOnlyTree(at: final, fileManager: fileManager)
            return ArchiveExportReceipt(root: final, manifest: manifest)
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }

    public func integrityCheck() throws -> ArchiveIntegrityReport {
        let cipherPassed = try database.cipherIntegrityCheck()
        let foreignKeyViolations = try database.atomicRead { database in
            try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").count
        }
        let candidates = try readyChunks()
        var issues: [ArchiveIntegrityIssue] = []
        for candidate in candidates {
            guard let chunk = candidate.chunk else {
                issues.append(
                    ArchiveIntegrityIssue(
                        code: "ready_chunk_record",
                        identity: candidate.identity
                    )
                )
                continue
            }
            do {
                _ = try ArchiveHEICChunkVerifier.verify(
                    paths: paths,
                    manifestRelativePath: chunk.manifestPath,
                    expectedChunkID: chunk.id,
                    expectedCaptureEpochID: chunk.captureEpochID,
                    expectedTargetWindowID: chunk.targetWindowID,
                    fileManager: fileManager
                )
            } catch {
                issues.append(
                    ArchiveIntegrityIssue(
                        code: "ready_chunk_integrity",
                        identity: chunk.id.uuidString.lowercased()
                    )
                )
            }
        }
        return ArchiveIntegrityReport(
            cipherIntegrityPassed: cipherPassed,
            foreignKeyViolationCount: foreignKeyViolations,
            checkedReadyChunkCount: candidates.count,
            issues: issues.sorted { ($0.code, $0.identity ?? "") < ($1.code, $1.identity ?? "") }
        )
    }

    public func quarantineReview() throws -> [ArchiveQuarantineItem] {
        try ArchivePathProvider.rejectSymbolicLink(at: paths.quarantine, fileManager: fileManager)
        return try fileManager.contentsOfDirectory(
            at: paths.quarantine,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ArchiveMaintenanceError.symbolicLinkForbidden
            }
            let aggregate = try aggregateIntegrity(at: url)
            return ArchiveQuarantineItem(
                relativePath: url.lastPathComponent,
                reason: url.lastPathComponent.split(separator: "-", maxSplits: 1).first.map(
                    String.init) ?? "unknown",
                byteCount: aggregate.byteCount,
                sha256: aggregate.sha256,
                isDirectory: values.isDirectory == true
            )
        }
    }

    public func repair() throws -> ArchiveRepairReport {
        let recovery = try database.repairArchive()
        let integrity = try integrityCheck()
        return ArchiveRepairReport(
            recovery: recovery,
            postRepairIntegrity: integrity,
            quarantine: try quarantineReview()
        )
    }

    private func exportRecord(frameID: UUID) throws -> ExportRecord {
        let source: ArchiveMomentSourceRecord
        do {
            source = try ArchiveMomentSourceStore(database: database).readySource(frameID: frameID)
        } catch {
            throw ArchiveMaintenanceError.sourceUnavailable
        }
        let row = try database.atomicRead { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT frames.captured_at, frames.bundle_id, frames.app_name,
                           frames.window_title, frames.url_host, frames.url_path,
                           CASE WHEN merged_text_records.state = 'ready'
                                THEN merged_text_records.approved_text ELSE '' END
                                AS approved_text,
                           CASE WHEN merged_text_records.state = 'ready'
                                THEN merged_text_records.transcript_text ELSE '' END
                                AS transcript_text
                    FROM frames
                    LEFT JOIN merged_text_records
                           ON merged_text_records.frame_id = frames.id
                    WHERE frames.id = ?
                    """,
                arguments: [frameID.uuidString.lowercased()]
            )
        }
        guard let row,
            let capturedAt = Self.decodeDate(row["captured_at"] as String),
            let bundleIdentifier = row["bundle_id"] as String?,
            !bundleIdentifier.isEmpty
        else { throw ArchiveMaintenanceError.sourceUnavailable }
        return ExportRecord(
            frameID: frameID,
            capturedAt: capturedAt,
            bundleIdentifier: bundleIdentifier,
            applicationName: row["app_name"],
            windowTitle: row["window_title"],
            host: row["url_host"],
            path: row["url_path"],
            approvedText: row["approved_text"],
            transcriptText: row["transcript_text"],
            source: source
        )
    }

    private func isAllowed(_ record: ExportRecord, by scope: ArchiveExportScope) -> Bool {
        let inInterval =
            record.capturedAt >= scope.allowedInterval.start
            && record.capturedAt < scope.allowedInterval.end
        let bundleAllowed = scope.allowedBundleIdentifiers.contains(record.bundleIdentifier)
        let hostAllowed = record.host.map(scope.allowedHosts.contains) ?? true
        return inInterval && bundleAllowed && hostAllowed
    }

    private func verifiedSourceBytes(_ record: ExportRecord, at sourceURL: URL) throws -> Data {
        let verified = try ArchiveHEICChunkVerifier.verify(
            paths: paths,
            manifestRelativePath: record.source.manifestPath,
            expectedCaptureEpochID: record.source.captureEpochID,
            expectedTargetWindowID: record.source.targetWindowID,
            fileManager: fileManager
        )
        guard verified.manifestSHA256 == record.source.manifestHash,
            let frame = verified.frames.first(where: { $0.id == record.frameID }),
            frame.archiveRelativePath == record.source.mediaPath.rawValue,
            frame.sha256 == record.source.mediaHash,
            frame.byteCount == record.source.mediaByteCount
        else { throw ArchiveMaintenanceError.sourceUnavailable }
        let bytes = try Data(contentsOf: sourceURL)
        guard bytes.count == record.source.mediaByteCount,
            Data(SHA256.hash(data: bytes)) == record.source.mediaHash
        else { throw ArchiveMaintenanceError.sourceUnavailable }
        return bytes
    }

    private func readyChunks() throws -> [ReadyChunkCandidate] {
        try database.atomicRead { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, relative_path, capture_epoch_id, target_window_id
                    FROM media_chunks
                    WHERE state = 'ready' AND codec = 'heicKeyframes'
                    ORDER BY id
                    """
            ).map { row in
                let identity = row["id"] as String
                guard let id = UUID(uuidString: row["id"] as String),
                    let epoch = UUID(uuidString: row["capture_epoch_id"] as String),
                    let target = row["target_window_id"] as Int64?,
                    target > 0,
                    target <= Int64(UInt32.max),
                    let path = try? ArchiveRelativePath(row["relative_path"] as String)
                else { return ReadyChunkCandidate(identity: identity, chunk: nil) }
                return ReadyChunkCandidate(
                    identity: identity,
                    chunk: ReadyChunk(
                        id: id,
                        manifestPath: path,
                        captureEpochID: epoch,
                        targetWindowID: UInt32(target)
                    )
                )
            }
        }
    }

    private func isCurrent(_ record: ExportRecord, database: Database) throws -> Bool {
        let count =
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    LEFT JOIN merged_text_records ON merged_text_records.frame_id = frames.id
                    WHERE frames.id = ?
                      AND frames.captured_at = ?
                      AND frames.bundle_id = ?
                      AND frames.url_host IS ?
                      AND frames.media_path = ?
                      AND frames.media_sha256 = ?
                      AND frames.media_byte_count = ?
                      AND frames.visual_state <> 'suppressed'
                      AND (frames.text_state = 'ready' OR frames.visual_state = 'ready')
                      AND media_chunks.state = 'ready'
                      AND CASE WHEN merged_text_records.state = 'ready'
                               THEN merged_text_records.approved_text ELSE '' END = ?
                      AND CASE WHEN merged_text_records.state = 'ready'
                               THEN merged_text_records.transcript_text ELSE '' END = ?
                    """,
                arguments: [
                    record.frameID.uuidString.lowercased(),
                    record.capturedAt.formatted(
                        Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
                    ),
                    record.bundleIdentifier,
                    record.host,
                    record.source.mediaPath.rawValue,
                    Self.hex(record.source.mediaHash),
                    record.source.mediaByteCount,
                    record.approvedText,
                    record.transcriptText,
                ]
            ) ?? 0
        return count == 1
    }

    private func aggregateIntegrity(at root: URL) throws -> (byteCount: Int, sha256: String) {
        let rootValues = try root.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard rootValues.isSymbolicLink != true else {
            throw ArchiveMaintenanceError.symbolicLinkForbidden
        }
        if rootValues.isRegularFile == true {
            let data = try Data(contentsOf: root)
            return (data.count, Self.hex(SHA256.hash(data: data)))
        }
        guard rootValues.isDirectory == true,
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        else { throw ArchiveMaintenanceError.sourceUnavailable }
        let base = root.standardizedFileURL.path
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw ArchiveMaintenanceError.symbolicLinkForbidden
            }
            if values.isRegularFile == true {
                files.append((String(url.standardizedFileURL.path.dropFirst(base.count + 1)), url))
            }
        }
        var aggregate = Data()
        var byteCount = 0
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            let data = try Data(contentsOf: url)
            byteCount += data.count
            aggregate.append(Data(relative.utf8))
            aggregate.append(0)
            aggregate.append(Data(SHA256.hash(data: data)))
        }
        return (byteCount, Self.hex(SHA256.hash(data: aggregate)))
    }

    private func write(_ data: Data, to destination: URL) throws {
        try ArchivePathProvider.createOwnerOnlyDirectory(
            at: destination.deletingLastPathComponent(),
            beneath: paths.root,
            fileManager: fileManager
        )
        try data.write(to: destination, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: ArchivePathProvider.filePermissions],
            ofItemAtPath: destination.path
        )
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func exportEvidencePath(_ record: ExportRecord) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: record.capturedAt
        )
        return String(
            format: "media/%04d/%02d/%02d/%@.heic",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            record.frameID.uuidString.lowercased()
        )
    }

    private static func decodeDate(_ value: String) -> Date? {
        try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private static func hex<H: Sequence>(_ bytes: H) -> String where H.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    static var archiveMaintenance: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var archiveMaintenance: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
