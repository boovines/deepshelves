import Accelerate
import CryptoKit
import Darwin
import Foundation
import GRDB

public enum ArchiveVectorStoreError: Error, Equatable, Sendable {
    case fileBackedArchiveRequired
    case invalidModelIdentity
    case invalidRequest
    case staleLease
    case sourceChanged
    case conflictingVector
    case invalidHeader
    case wrongModel
    case invalidOffset
    case truncatedPayload
    case checksumMismatch
    case duplicateOffset
    case publicationUnavailable
    case compactionRecoveryRequired
    case injectedCrash(ArchiveVectorFault)
}

public enum ArchiveVectorFault: String, Codable, Equatable, Sendable {
    case afterFileSync
    case afterDatabaseStage
    case afterCompactionSwap
    case afterCompactionDatabase
}

public struct ArchiveVectorModelIdentity: Equatable, Sendable {
    public let modelHash: Data
    public let jobVersion: String
    public let producerName: String
    public let producerSemanticVersion: String
    public let preprocessingVersion: String
    public let dimension: Int

    public init(
        modelHash: Data,
        jobVersion: String,
        producerName: String,
        producerSemanticVersion: String,
        preprocessingVersion: String,
        dimension: Int
    ) throws {
        guard modelHash.count == 32, (1...4_096).contains(dimension),
            Self.validToken(jobVersion), Self.validToken(producerName),
            Self.validToken(producerSemanticVersion), Self.validToken(preprocessingVersion)
        else {
            throw ArchiveVectorStoreError.invalidModelIdentity
        }
        self.modelHash = modelHash
        self.jobVersion = jobVersion
        self.producerName = producerName
        self.producerSemanticVersion = producerSemanticVersion
        self.preprocessingVersion = preprocessingVersion
        self.dimension = dimension
    }

    public var modelHashHex: String { modelHash.lowercaseHex }

    public var relativePath: ArchiveRelativePath {
        get throws {
            try ArchiveRelativePath("vectors/mobileclip-s0/\(modelHashHex).f16")
        }
    }

    fileprivate var vectorByteCount: Int { dimension * MemoryLayout<UInt16>.size }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$", options: .regularExpression)
                != nil
    }
}

public struct ArchiveVectorAppendRequest: Sendable {
    public let lease: EnrichmentJobLease
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let policyGeneration: UInt64
    public let sourceHash: Data
    public let model: ArchiveVectorModelIdentity
    public let values: [Float]

    public init(
        lease: EnrichmentJobLease,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        policyGeneration: UInt64,
        sourceHash: Data,
        model: ArchiveVectorModelIdentity,
        values: [Float]
    ) {
        self.lease = lease
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.policyGeneration = policyGeneration
        self.sourceHash = sourceHash
        self.model = model
        self.values = values
    }
}

public struct ArchiveVectorAppendResult: Equatable, Sendable {
    public let frameID: UUID
    public let byteOffset: Int64
    public let byteLength: Int
    public let float16Norm: Double
    public let contentHash: Data
    public let reusedExistingStage: Bool
}

public struct ArchiveVectorRecoveryReport: Equatable, Sendable {
    public let originalByteCount: Int64
    public let repairedByteCount: Int64
    public let truncatedTailBytes: Int64
    public let promotedStages: Int
    public let compactionRecovered: Bool
}

public struct ArchiveVectorCompactionReport: Equatable, Sendable {
    public let retainedVectors: Int
    public let removedVectors: Int
    public let originalByteCount: Int64
    public let compactedByteCount: Int64
}

public final class ArchiveVectorStore: @unchecked Sendable {
    public static let headerByteCount = 192
    public static let magic = "DSVEC002"

    private let database: ArchiveDatabase
    private let paths: ArchivePaths
    private let fileStore: ArchiveFileStore
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()

    public init(database: ArchiveDatabase, fileManager: FileManager = .default) throws {
        guard let paths = database.paths, let fileStore = database.fileStore else {
            throw ArchiveVectorStoreError.fileBackedArchiveRequired
        }
        self.database = database
        self.paths = paths
        self.fileStore = fileStore
        self.fileManager = fileManager
    }

    public func stage(
        _ request: ArchiveVectorAppendRequest,
        fault: ArchiveVectorFault? = nil
    ) throws -> ArchiveVectorAppendResult {
        try lock.withLock {
            try validate(request)
            _ = try recoverCompactionIfNeeded(model: request.model)
            let encoded = try Self.encodeFloat16(request.values)
            let contentHash = Data(SHA256.hash(data: encoded.bytes))
            let generation = try ensureFile(model: request.model)
            let url = fileStore.url(for: try request.model.relativePath)
            let descriptor = try openLocked(url, flags: O_RDWR)
            defer { closeLocked(descriptor) }
            try validateHeader(
                descriptor: descriptor,
                model: request.model,
                expectedGeneration: generation
            )
            try validateLeaseAndSource(request)

            if let existing = try existingRecord(frameID: request.lease.parentID) {
                if existing.state != "stale" {
                    guard existing.modelHash == request.model.modelHashHex,
                        existing.dimension == request.model.dimension,
                        existing.contentHash == contentHash,
                        existing.state == "staged" || existing.state == "ready"
                    else {
                        throw ArchiveVectorStoreError.conflictingVector
                    }
                    try verify(existing, model: request.model, descriptor: descriptor)
                    return ArchiveVectorAppendResult(
                        frameID: request.lease.parentID,
                        byteOffset: existing.byteOffset,
                        byteLength: request.model.vectorByteCount,
                        float16Norm: existing.norm,
                        contentHash: contentHash,
                        reusedExistingStage: true
                    )
                }
            }

            let committedEnd = try canonicalPayloadEnd(model: request.model)
            let physicalEnd = try fileSize(descriptor)
            guard committedEnd <= physicalEnd else {
                throw ArchiveVectorStoreError.truncatedPayload
            }
            if physicalEnd > committedEnd {
                guard ftruncate(descriptor, off_t(committedEnd)) == 0 else {
                    throw ArchiveVectorStoreError.publicationUnavailable
                }
            }
            guard pwriteAll(encoded.bytes, descriptor: descriptor, offset: committedEnd),
                fsync(descriptor) == 0
            else {
                throw ArchiveVectorStoreError.publicationUnavailable
            }
            if fault == .afterFileSync {
                throw ArchiveVectorStoreError.injectedCrash(.afterFileSync)
            }

            do {
                try stageDatabase(
                    request,
                    byteOffset: committedEnd,
                    norm: encoded.norm,
                    contentHash: contentHash
                )
            } catch {
                _ = ftruncate(descriptor, off_t(committedEnd))
                _ = fsync(descriptor)
                throw error
            }
            if fault == .afterDatabaseStage {
                throw ArchiveVectorStoreError.injectedCrash(.afterDatabaseStage)
            }
            return ArchiveVectorAppendResult(
                frameID: request.lease.parentID,
                byteOffset: committedEnd,
                byteLength: request.model.vectorByteCount,
                float16Norm: encoded.norm,
                contentHash: contentHash,
                reusedExistingStage: false
            )
        }
    }

    public func finalize(_ lease: EnrichmentJobLease, model: ArchiveVectorModelIdentity) throws {
        try lock.withLock {
            try recoverCompactionIfNeeded(model: model)
            guard let record = try existingRecord(frameID: lease.parentID),
                record.modelHash == model.modelHashHex,
                record.dimension == model.dimension,
                record.state == "staged" || record.state == "ready"
            else {
                throw ArchiveVectorStoreError.publicationUnavailable
            }
            let generation = try databaseGeneration(model)
            let descriptor = try openLocked(fileStore.url(for: model.relativePath), flags: O_RDONLY)
            defer { closeLocked(descriptor) }
            try validateHeader(descriptor: descriptor, model: model, expectedGeneration: generation)
            try verify(record, model: model, descriptor: descriptor)
            try database.atomicWrite { database in
                guard try Self.jobMatchesSucceeded(lease, in: database) else {
                    throw ArchiveVectorStoreError.staleLease
                }
                if record.state == "staged" {
                    try database.execute(
                        sql:
                            "UPDATE vector_offsets SET state = 'ready' WHERE frame_id = ? AND state = 'staged'",
                        arguments: [Self.encode(lease.parentID)]
                    )
                    guard database.changesCount == 1 else {
                        throw ArchiveVectorStoreError.publicationUnavailable
                    }
                    try database.execute(
                        sql:
                            "UPDATE artifacts SET state = 'ready' WHERE frame_id = ? AND kind = 'visualVector' AND model_hash = ? AND state = 'staged'",
                        arguments: [Self.encode(lease.parentID), model.modelHashHex]
                    )
                    guard database.changesCount == 1 else {
                        throw ArchiveVectorStoreError.publicationUnavailable
                    }
                    try database.execute(
                        sql:
                            "UPDATE frames SET visual_state = 'ready' WHERE id = ? AND visual_state = 'pending'",
                        arguments: [Self.encode(lease.parentID)]
                    )
                    guard database.changesCount == 1 else {
                        throw ArchiveVectorStoreError.sourceChanged
                    }
                }
            }
        }
    }

    public func read(frameID: UUID, model: ArchiveVectorModelIdentity) throws -> [Float] {
        try lock.withLock {
            try recoverCompactionIfNeeded(model: model)
            guard let record = try existingRecord(frameID: frameID), record.state == "ready" else {
                throw ArchiveVectorStoreError.publicationUnavailable
            }
            guard record.modelHash == model.modelHashHex else {
                throw ArchiveVectorStoreError.wrongModel
            }
            let descriptor = try openLocked(fileStore.url(for: model.relativePath), flags: O_RDONLY)
            defer { closeLocked(descriptor) }
            try validateHeader(
                descriptor: descriptor,
                model: model,
                expectedGeneration: try databaseGeneration(model)
            )
            let bytes = try verify(record, model: model, descriptor: descriptor)
            return try Self.decodeFloat16(bytes, dimension: model.dimension)
        }
    }

    public func recover(model: ArchiveVectorModelIdentity) throws -> ArchiveVectorRecoveryReport {
        try lock.withLock {
            let recoveredCompaction = try recoverCompactionIfNeeded(model: model)
            let generation = try ensureFile(model: model)
            let descriptor = try openLocked(fileStore.url(for: model.relativePath), flags: O_RDWR)
            defer { closeLocked(descriptor) }
            try validateHeader(descriptor: descriptor, model: model, expectedGeneration: generation)
            let original = try fileSize(descriptor)
            let records = try allRecords(model: model, states: ["ready", "staged"])
            let duplicateCount =
                Dictionary(grouping: records, by: \.byteOffset)
                .values.first(where: { $0.count > 1 })?.count ?? 0
            guard duplicateCount == 0 else { throw ArchiveVectorStoreError.duplicateOffset }
            for record in records {
                _ = try verify(record, model: model, descriptor: descriptor)
            }
            var promoted = 0
            for record in records where record.state == "staged" {
                if try promoteRecoveredStage(record, model: model) { promoted += 1 }
            }
            let expected = try canonicalPayloadEnd(model: model)
            let current = try fileSize(descriptor)
            guard current >= expected else { throw ArchiveVectorStoreError.truncatedPayload }
            if current > expected {
                guard ftruncate(descriptor, off_t(expected)) == 0, fsync(descriptor) == 0 else {
                    throw ArchiveVectorStoreError.publicationUnavailable
                }
            }
            return ArchiveVectorRecoveryReport(
                originalByteCount: original,
                repairedByteCount: expected,
                truncatedTailBytes: max(0, original - expected),
                promotedStages: promoted,
                compactionRecovered: recoveredCompaction
            )
        }
    }

    public func compact(
        model: ArchiveVectorModelIdentity,
        fault: ArchiveVectorFault? = nil
    ) throws -> ArchiveVectorCompactionReport {
        try lock.withLock {
            _ = try recover(model: model)
            let oldGeneration = try databaseGeneration(model)
            let records = try allRecords(model: model, states: ["ready", "staged"])
                .sorted { Self.encode($0.frameID) < Self.encode($1.frameID) }
            let removedCount = try staleArtifactCount(model: model)
            let canonicalURL = fileStore.url(for: try model.relativePath)
            let oldDescriptor = try openLocked(canonicalURL, flags: O_RDONLY)
            var payloads: [(VectorRecord, Data)] = []
            do {
                for record in records {
                    payloads.append(
                        (record, try verify(record, model: model, descriptor: oldDescriptor)))
                }
            } catch {
                closeLocked(oldDescriptor)
                throw error
            }
            let originalBytes = try fileSize(oldDescriptor)
            closeLocked(oldDescriptor)

            let newGeneration = UUID()
            let tempURL = canonicalURL.deletingLastPathComponent().appending(
                path: ".\(model.modelHashHex).compacting-\(newGeneration.uuidString.lowercased())"
            )
            let backupURL = canonicalURL.deletingLastPathComponent().appending(
                path: ".\(model.modelHashHex).backup-\(oldGeneration.uuidString.lowercased())"
            )
            let journalURL = compactionJournalURL(model)
            let mappings = try writeCompactedFile(
                payloads: payloads,
                model: model,
                generation: newGeneration,
                to: tempURL
            )
            let journal = CompactionJournal(
                modelHash: model.modelHashHex,
                oldGeneration: oldGeneration,
                newGeneration: newGeneration,
                backupName: backupURL.lastPathComponent
            )
            try writeOwnerOnly(try JSONEncoder().encode(journal), to: journalURL)
            try fileManager.moveItem(at: canonicalURL, to: backupURL)
            try fileManager.moveItem(at: tempURL, to: canonicalURL)
            try synchronizeDirectory(canonicalURL.deletingLastPathComponent())
            if fault == .afterCompactionSwap {
                throw ArchiveVectorStoreError.injectedCrash(.afterCompactionSwap)
            }

            try database.atomicWrite { database in
                for mapping in mappings {
                    try database.execute(
                        sql:
                            "UPDATE vector_offsets SET byte_offset = ? WHERE frame_id = ? AND model_hash = ?",
                        arguments: [
                            mapping.offset, Self.encode(mapping.frameID), model.modelHashHex,
                        ]
                    )
                    guard database.changesCount == 1 else {
                        throw ArchiveVectorStoreError.publicationUnavailable
                    }
                    try database.execute(
                        sql:
                            "UPDATE artifacts SET locator_value = ? WHERE frame_id = ? AND kind = 'visualVector' AND model_hash = ? AND state IN ('ready', 'staged')",
                        arguments: [
                            Self.locator(model: model, offset: mapping.offset),
                            Self.encode(mapping.frameID), model.modelHashHex,
                        ]
                    )
                }
                try database.execute(
                    sql: "DELETE FROM vector_offsets WHERE model_hash = ? AND state = 'stale'",
                    arguments: [model.modelHashHex]
                )
                try database.execute(
                    sql:
                        "DELETE FROM artifacts WHERE kind = 'visualVector' AND model_hash = ? AND state = 'stale'",
                    arguments: [model.modelHashHex]
                )
                try Self.setGeneration(newGeneration, model: model, in: database)
            }
            if fault == .afterCompactionDatabase {
                throw ArchiveVectorStoreError.injectedCrash(.afterCompactionDatabase)
            }
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.removeItem(at: journalURL)
            try synchronizeDirectory(canonicalURL.deletingLastPathComponent())
            return ArchiveVectorCompactionReport(
                retainedVectors: mappings.count,
                removedVectors: removedCount,
                originalByteCount: originalBytes,
                compactedByteCount: Int64(
                    Self.headerByteCount + mappings.count * model.vectorByteCount)
            )
        }
    }

    public func requestCompleteRebuild(model: ArchiveVectorModelIdentity) throws {
        try lock.withLock {
            try database.atomicWrite { database in
                try database.execute(
                    sql: "DELETE FROM vector_offsets WHERE model_hash = ?",
                    arguments: [model.modelHashHex]
                )
                try database.execute(
                    sql: "DELETE FROM artifacts WHERE kind = 'visualVector' AND model_hash = ?",
                    arguments: [model.modelHashHex]
                )
                try database.execute(
                    sql:
                        "UPDATE frames SET visual_state = 'pending' WHERE visual_state <> 'suppressed' AND id IN (SELECT parent_id FROM processing_jobs WHERE kind IN ('visualVector', 'visual-vector'))"
                )
                try database.execute(
                    sql:
                        "UPDATE processing_jobs SET kind = 'visualVector', producer_version = ?, state = 'queued', attempts = 0, next_attempt_at = NULL, error_code = NULL, lease_expires_at = NULL WHERE kind IN ('visualVector', 'visual-vector') AND state <> 'cancelled'",
                    arguments: [model.jobVersion]
                )
                try database.execute(
                    sql: "DELETE FROM archive_meta WHERE key = ?",
                    arguments: [Self.generationKey(model)]
                )
            }
            let url = fileStore.url(for: try model.relativePath)
            try? fileManager.removeItem(at: url)
            try? fileManager.removeItem(at: compactionJournalURL(model))
            _ = try ensureFile(model: model)
        }
    }

    private func validate(_ request: ArchiveVectorAppendRequest) throws {
        var norm = 0.0
        for value in request.values { norm += Double(value) * Double(value) }
        guard request.lease.kind == .visualVector,
            request.lease.producerVersion == request.model.jobVersion,
            request.targetWindowID > 0,
            request.policyGeneration > 0, request.policyGeneration <= UInt64(Int64.max),
            request.sourceHash.count == 32,
            request.values.count == request.model.dimension,
            request.values.allSatisfy(\.isFinite), abs(sqrt(norm) - 1) <= 0.000_01
        else {
            throw ArchiveVectorStoreError.invalidRequest
        }
    }

    private func validateLeaseAndSource(_ request: ArchiveVectorAppendRequest) throws {
        let valid = try database.atomicRead { database in
            let count =
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM processing_jobs jobs
                        JOIN frames ON frames.id = jobs.parent_id
                        JOIN media_chunks ON media_chunks.id = frames.chunk_id
                        JOIN artifacts thumbs ON thumbs.frame_id = frames.id
                        WHERE jobs.id = ? AND jobs.parent_id = ?
                          AND jobs.kind IN ('visualVector', 'visual-vector')
                          AND jobs.state = 'leased' AND jobs.attempts = ?
                          AND jobs.producer_version = ? AND jobs.lease_expires_at = ?
                          AND frames.capture_epoch_id = ? AND frames.target_window_id = ?
                          AND frames.policy_generation = ? AND frames.visual_state = 'pending'
                          AND frames.schema_version >= 2 AND media_chunks.state = 'ready'
                          AND thumbs.kind = 'thumbnail' AND thumbs.state = 'ready'
                          AND thumbs.locator_value = frames.thumbnail_path
                          AND thumbs.content_hash = ?
                        """,
                    arguments: [
                        Self.encode(request.lease.jobID), Self.encode(request.lease.parentID),
                        request.lease.attemptCount, request.lease.producerVersion,
                        Self.encode(request.lease.expiresAt), Self.encode(request.captureEpochID),
                        request.targetWindowID, Int64(request.policyGeneration),
                        request.sourceHash.lowercaseHex,
                    ]
                ) ?? 0
            return count == 1
        }
        guard valid else { throw ArchiveVectorStoreError.staleLease }
    }

    private func stageDatabase(
        _ request: ArchiveVectorAppendRequest,
        byteOffset: Int64,
        norm: Double,
        contentHash: Data
    ) throws {
        try database.atomicWrite { database in
            guard try Self.leaseAndSourceMatch(request, in: database) else {
                throw ArchiveVectorStoreError.staleLease
            }
            let frame = Self.encode(request.lease.parentID)
            try database.execute(
                sql: "DELETE FROM vector_offsets WHERE frame_id = ? AND state = 'stale'",
                arguments: [frame]
            )
            try database.execute(
                sql: """
                    INSERT INTO vector_offsets(frame_id, model_hash, byte_offset, dimension, norm, state)
                    VALUES (?, ?, ?, ?, ?, 'staged')
                    """,
                arguments: [
                    frame, request.model.modelHashHex, byteOffset, request.model.dimension, norm,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO artifacts(
                        id, frame_id, kind, producer_name, producer_version, model_hash,
                        locator_kind, locator_value, content_hash, state
                    ) VALUES (?, ?, 'visualVector', ?, ?, ?, 'relativeFileOffset', ?, ?, 'staged')
                    """,
                arguments: [
                    UUID().uuidString.lowercased(), frame, request.model.producerName,
                    request.model.producerSemanticVersion, request.model.modelHashHex,
                    Self.locator(model: request.model, offset: byteOffset),
                    contentHash.lowercaseHex,
                ]
            )
        }
    }

    private static func leaseAndSourceMatch(
        _ request: ArchiveVectorAppendRequest,
        in database: Database
    ) throws -> Bool {
        let count =
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM processing_jobs jobs
                    JOIN frames ON frames.id = jobs.parent_id
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    JOIN artifacts thumbs ON thumbs.frame_id = frames.id
                    WHERE jobs.id = ? AND jobs.parent_id = ?
                      AND jobs.kind IN ('visualVector', 'visual-vector')
                      AND jobs.state = 'leased' AND jobs.attempts = ?
                      AND jobs.producer_version = ? AND jobs.lease_expires_at = ?
                      AND frames.capture_epoch_id = ? AND frames.target_window_id = ?
                      AND frames.policy_generation = ? AND frames.visual_state = 'pending'
                      AND frames.schema_version >= 2 AND media_chunks.state = 'ready'
                      AND thumbs.kind = 'thumbnail' AND thumbs.state = 'ready'
                      AND thumbs.locator_value = frames.thumbnail_path
                      AND thumbs.content_hash = ?
                    """,
                arguments: [
                    encode(request.lease.jobID), encode(request.lease.parentID),
                    request.lease.attemptCount, request.lease.producerVersion,
                    encode(request.lease.expiresAt), encode(request.captureEpochID),
                    request.targetWindowID, Int64(request.policyGeneration),
                    request.sourceHash.lowercaseHex,
                ]
            ) ?? 0
        return count == 1
    }

    private func existingRecord(frameID: UUID) throws -> VectorRecord? {
        try database.atomicRead { database in
            try Self.fetchRecord(frameID: frameID, in: database)
        }
    }

    private static func fetchRecord(frameID: UUID, in database: Database) throws -> VectorRecord? {
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT offsets.frame_id, offsets.model_hash, offsets.byte_offset,
                           offsets.dimension, offsets.norm, offsets.state,
                           artifacts.content_hash, artifacts.locator_value
                    FROM vector_offsets offsets
                    JOIN artifacts ON artifacts.frame_id = offsets.frame_id
                      AND artifacts.kind = 'visualVector'
                      AND artifacts.model_hash = offsets.model_hash
                      AND artifacts.state = offsets.state
                    WHERE offsets.frame_id = ?
                    ORDER BY artifacts.id DESC LIMIT 1
                    """,
                arguments: [encode(frameID)]
            )
        else { return nil }
        return try record(row)
    }

    private func allRecords(model: ArchiveVectorModelIdentity, states: [String]) throws
        -> [VectorRecord]
    {
        try database.atomicRead { database in
            let placeholders = states.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT offsets.frame_id, offsets.model_hash, offsets.byte_offset,
                           offsets.dimension, offsets.norm, offsets.state,
                           artifacts.content_hash, artifacts.locator_value
                    FROM vector_offsets offsets
                    JOIN artifacts ON artifacts.frame_id = offsets.frame_id
                      AND artifacts.kind = 'visualVector'
                      AND artifacts.model_hash = offsets.model_hash
                      AND artifacts.state = offsets.state
                    WHERE offsets.model_hash = ? AND offsets.state IN (\(placeholders))
                    ORDER BY offsets.byte_offset, offsets.frame_id
                    """,
                arguments: StatementArguments([model.modelHashHex] + states)
            ).map(Self.record)
        }
    }

    private static func record(_ row: Row) throws -> VectorRecord {
        let frame: String = row["frame_id"]
        let modelHash: String = row["model_hash"]
        let offset: Int64 = row["byte_offset"]
        let dimension: Int = row["dimension"]
        let norm: Double = row["norm"]
        let state: String = row["state"]
        let contentHash: String = row["content_hash"]
        let locator: String = row["locator_value"]
        guard let frameID = UUID(uuidString: frame),
            let hash = Data(lowercaseHex: contentHash), hash.count == 32,
            offset >= Int64(headerByteCount), dimension > 0, norm.isFinite,
            state == "ready" || state == "staged" || state == "stale"
        else {
            throw ArchiveVectorStoreError.invalidOffset
        }
        return VectorRecord(
            frameID: frameID, modelHash: modelHash, byteOffset: offset,
            dimension: dimension, norm: norm, state: state,
            contentHash: hash, locator: locator
        )
    }

    @discardableResult
    private func verify(
        _ record: VectorRecord,
        model: ArchiveVectorModelIdentity,
        descriptor: Int32
    ) throws -> Data {
        guard record.dimension == model.dimension,
            record.byteOffset >= Int64(Self.headerByteCount),
            (record.byteOffset - Int64(Self.headerByteCount)) % Int64(model.vectorByteCount) == 0,
            record.locator == Self.locator(model: model, offset: record.byteOffset)
        else {
            throw ArchiveVectorStoreError.invalidOffset
        }
        let end = record.byteOffset + Int64(model.vectorByteCount)
        guard end <= (try fileSize(descriptor)) else {
            throw ArchiveVectorStoreError.truncatedPayload
        }
        var bytes = Data(repeating: 0, count: model.vectorByteCount)
        let read = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, off_t(record.byteOffset))
        }
        guard read == model.vectorByteCount else { throw ArchiveVectorStoreError.truncatedPayload }
        guard Data(SHA256.hash(data: bytes)) == record.contentHash else {
            throw ArchiveVectorStoreError.checksumMismatch
        }
        let decoded = try Self.decodeFloat16(bytes, dimension: model.dimension)
        let measuredNorm = sqrt(decoded.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard abs(measuredNorm - record.norm) <= 0.000_000_1,
            abs(record.norm - 1) <= 0.005
        else {
            throw ArchiveVectorStoreError.checksumMismatch
        }
        return bytes
    }

    private func canonicalPayloadEnd(model: ArchiveVectorModelIdentity) throws -> Int64 {
        try database.atomicRead { database in
            let maximum = try Int64.fetchOne(
                database,
                sql: "SELECT MAX(byte_offset) FROM vector_offsets WHERE model_hash = ?",
                arguments: [model.modelHashHex]
            )
            return (maximum ?? Int64(Self.headerByteCount))
                + (maximum == nil ? 0 : Int64(model.vectorByteCount))
        }
    }

    private func ensureFile(model: ArchiveVectorModelIdentity) throws -> UUID {
        let url = fileStore.url(for: try model.relativePath)
        if fileManager.fileExists(atPath: url.path) {
            let descriptor = try openLocked(url, flags: O_RDONLY)
            defer { closeLocked(descriptor) }
            let header = try readHeader(descriptor)
            try validateHeaderIdentity(header, model: model)
            let existingGeneration = try databaseGenerationOptional(model)
            if let existingGeneration {
                guard existingGeneration == header.generation else {
                    throw ArchiveVectorStoreError.compactionRecoveryRequired
                }
            } else {
                let count = try database.atomicRead { database in
                    try Int.fetchOne(
                        database,
                        sql: "SELECT COUNT(*) FROM vector_offsets WHERE model_hash = ?",
                        arguments: [model.modelHashHex]
                    ) ?? 0
                }
                guard count == 0 else { throw ArchiveVectorStoreError.invalidHeader }
                try database.atomicWrite { database in
                    try Self.setGeneration(header.generation, model: model, in: database)
                }
            }
            return header.generation
        }
        let generation = UUID()
        _ = try fileStore.write(
            Self.header(model: model, generation: generation), to: model.relativePath)
        try database.atomicWrite { database in
            try Self.setGeneration(generation, model: model, in: database)
        }
        return generation
    }

    private func validateHeader(
        descriptor: Int32,
        model: ArchiveVectorModelIdentity,
        expectedGeneration: UUID
    ) throws {
        let header = try readHeader(descriptor)
        try validateHeaderIdentity(header, model: model)
        guard header.generation == expectedGeneration else {
            throw ArchiveVectorStoreError.compactionRecoveryRequired
        }
    }

    private func validateHeaderIdentity(_ header: VectorHeader, model: ArchiveVectorModelIdentity)
        throws
    {
        guard header.modelHash == model.modelHash,
            header.dimension == model.dimension,
            header.vectorByteCount == model.vectorByteCount,
            header.producerHash
                == Data(SHA256.hash(data: Data(model.producerSemanticVersion.utf8))),
            header.preprocessingHash
                == Data(SHA256.hash(data: Data(model.preprocessingVersion.utf8)))
        else {
            throw ArchiveVectorStoreError.wrongModel
        }
    }

    private func readHeader(_ descriptor: Int32) throws -> VectorHeader {
        var bytes = Data(repeating: 0, count: Self.headerByteCount)
        let count = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count == Self.headerByteCount,
            String(data: bytes[0..<8], encoding: .utf8) == Self.magic,
            Self.readInteger(UInt32.self, bytes, 8) == 2,
            Self.readInteger(UInt32.self, bytes, 12) == UInt32(Self.headerByteCount),
            let dimension = Self.readInteger(UInt32.self, bytes, 16),
            let vectorBytes = Self.readInteger(UInt32.self, bytes, 20),
            Data(SHA256.hash(data: bytes[0..<136])) == bytes[136..<168],
            let generation = Self.uuid(bytes[120..<136])
        else {
            throw ArchiveVectorStoreError.invalidHeader
        }
        return VectorHeader(
            dimension: Int(dimension), vectorByteCount: Int(vectorBytes),
            modelHash: Data(bytes[24..<56]), producerHash: Data(bytes[56..<88]),
            preprocessingHash: Data(bytes[88..<120]), generation: generation
        )
    }

    private static func header(model: ArchiveVectorModelIdentity, generation: UUID) -> Data {
        var data = Data(repeating: 0, count: headerByteCount)
        data.replaceSubrange(0..<8, with: Data(magic.utf8))
        writeInteger(UInt32(2), at: 8, into: &data)
        writeInteger(UInt32(headerByteCount), at: 12, into: &data)
        writeInteger(UInt32(model.dimension), at: 16, into: &data)
        writeInteger(UInt32(model.vectorByteCount), at: 20, into: &data)
        data.replaceSubrange(24..<56, with: model.modelHash)
        data.replaceSubrange(
            56..<88,
            with: Data(SHA256.hash(data: Data(model.producerSemanticVersion.utf8)))
        )
        data.replaceSubrange(
            88..<120,
            with: Data(SHA256.hash(data: Data(model.preprocessingVersion.utf8)))
        )
        var uuid = generation.uuid
        withUnsafeBytes(of: &uuid) { data.replaceSubrange(120..<136, with: $0) }
        data.replaceSubrange(136..<168, with: Data(SHA256.hash(data: data[0..<136])))
        return data
    }

    private func databaseGeneration(_ model: ArchiveVectorModelIdentity) throws -> UUID {
        guard let generation = try databaseGenerationOptional(model) else {
            throw ArchiveVectorStoreError.invalidHeader
        }
        return generation
    }

    private func databaseGenerationOptional(_ model: ArchiveVectorModelIdentity) throws -> UUID? {
        try database.atomicRead { database in
            guard
                let value = try String.fetchOne(
                    database,
                    sql: "SELECT value FROM archive_meta WHERE key = ?",
                    arguments: [Self.generationKey(model)]
                )
            else { return nil }
            guard let generation = UUID(uuidString: value) else {
                throw ArchiveVectorStoreError.invalidHeader
            }
            return generation
        }
    }

    private static func setGeneration(
        _ generation: UUID,
        model: ArchiveVectorModelIdentity,
        in database: Database
    ) throws {
        try database.execute(
            sql:
                "INSERT INTO archive_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [generationKey(model), generation.uuidString.lowercased()]
        )
    }

    private func promoteRecoveredStage(
        _ record: VectorRecord,
        model: ArchiveVectorModelIdentity
    ) throws -> Bool {
        try database.atomicWrite { database in
            let succeeded =
                try Int.fetchOne(
                    database,
                    sql:
                        "SELECT COUNT(*) FROM processing_jobs WHERE parent_id = ? AND kind IN ('visualVector', 'visual-vector') AND producer_version = ? AND state = 'succeeded'",
                    arguments: [Self.encode(record.frameID), model.jobVersion]
                ) ?? 0
            guard succeeded == 1 else { return false }
            try database.execute(
                sql:
                    "UPDATE vector_offsets SET state = 'ready' WHERE frame_id = ? AND state = 'staged'",
                arguments: [Self.encode(record.frameID)]
            )
            try database.execute(
                sql:
                    "UPDATE artifacts SET state = 'ready' WHERE frame_id = ? AND kind = 'visualVector' AND model_hash = ? AND state = 'staged'",
                arguments: [Self.encode(record.frameID), model.modelHashHex]
            )
            try database.execute(
                sql:
                    "UPDATE frames SET visual_state = 'ready' WHERE id = ? AND visual_state = 'pending'",
                arguments: [Self.encode(record.frameID)]
            )
            return true
        }
    }

    private func recoverCompactionIfNeeded(model: ArchiveVectorModelIdentity) throws -> Bool {
        let journalURL = compactionJournalURL(model)
        guard fileManager.fileExists(atPath: journalURL.path) else { return false }
        let journal = try JSONDecoder().decode(
            CompactionJournal.self,
            from: Data(contentsOf: journalURL)
        )
        guard journal.modelHash == model.modelHashHex,
            !journal.backupName.contains("/"), !journal.backupName.contains("..")
        else {
            throw ArchiveVectorStoreError.compactionRecoveryRequired
        }
        let canonical = fileStore.url(for: try model.relativePath)
        let backup = canonical.deletingLastPathComponent().appending(path: journal.backupName)
        let databaseGeneration = try databaseGeneration(model)
        if databaseGeneration == journal.oldGeneration {
            guard fileManager.fileExists(atPath: backup.path) else {
                throw ArchiveVectorStoreError.compactionRecoveryRequired
            }
            try? fileManager.removeItem(at: canonical)
            try fileManager.moveItem(at: backup, to: canonical)
        } else if databaseGeneration == journal.newGeneration {
            try? fileManager.removeItem(at: backup)
        } else {
            throw ArchiveVectorStoreError.compactionRecoveryRequired
        }
        try? fileManager.removeItem(at: journalURL)
        try synchronizeDirectory(canonical.deletingLastPathComponent())
        return true
    }

    private func writeCompactedFile(
        payloads: [(VectorRecord, Data)],
        model: ArchiveVectorModelIdentity,
        generation: UUID,
        to url: URL
    ) throws -> [(frameID: UUID, offset: Int64)] {
        guard
            fileManager.createFile(
                atPath: url.path,
                contents: Self.header(model: model, generation: generation),
                attributes: [.posixPermissions: ArchivePathProvider.filePermissions]
            )
        else {
            throw ArchiveVectorStoreError.publicationUnavailable
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var offset = Int64(Self.headerByteCount)
        var mappings: [(UUID, Int64)] = []
        for (record, bytes) in payloads {
            try handle.write(contentsOf: bytes)
            mappings.append((record.frameID, offset))
            offset += Int64(model.vectorByteCount)
        }
        try handle.synchronize()
        return mappings
    }

    private func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: ArchivePathProvider.filePermissions],
            ofItemAtPath: url.path
        )
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func staleArtifactCount(model: ArchiveVectorModelIdentity) throws -> Int {
        try database.atomicRead { database in
            try Int.fetchOne(
                database,
                sql:
                    "SELECT COUNT(*) FROM artifacts WHERE kind = 'visualVector' AND model_hash = ? AND state = 'stale'",
                arguments: [model.modelHashHex]
            ) ?? 0
        }
    }

    private func openLocked(_ url: URL, flags: Int32) throws -> Int32 {
        let descriptor = Darwin.open(url.path, flags | O_CLOEXEC)
        guard descriptor >= 0, flock(descriptor, flags == O_RDONLY ? LOCK_SH : LOCK_EX) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw ArchiveVectorStoreError.publicationUnavailable
        }
        return descriptor
    }

    private func closeLocked(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func fileSize(_ descriptor: Int32) throws -> Int64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ArchiveVectorStoreError.publicationUnavailable
        }
        return Int64(status.st_size)
    }

    private func pwriteAll(_ data: Data, descriptor: Int32, offset: Int64) -> Bool {
        data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = pwrite(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    buffer.count - written,
                    off_t(offset + Int64(written))
                )
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArchiveVectorStoreError.publicationUnavailable }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ArchiveVectorStoreError.publicationUnavailable }
    }

    private func compactionJournalURL(_ model: ArchiveVectorModelIdentity) -> URL {
        paths.vectors.appending(
            path: "mobileclip-s0/.\(model.modelHashHex).compaction.json"
        )
    }

    private static func generationKey(_ model: ArchiveVectorModelIdentity) -> String {
        "vector_generation:\(model.modelHashHex)"
    }

    private static func locator(model: ArchiveVectorModelIdentity, offset: Int64) -> String {
        "\((try? model.relativePath.rawValue) ?? "invalid")#\(offset):\(model.vectorByteCount)"
    }

    private static func encode(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func encode(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    private static func jobMatchesSucceeded(_ lease: EnrichmentJobLease, in database: Database)
        throws -> Bool
    {
        try Int.fetchOne(
            database,
            sql:
                "SELECT COUNT(*) FROM processing_jobs WHERE id = ? AND parent_id = ? AND kind IN ('visualVector', 'visual-vector') AND state = 'succeeded' AND attempts = ? AND producer_version = ?",
            arguments: [
                encode(lease.jobID), encode(lease.parentID), lease.attemptCount,
                lease.producerVersion,
            ]
        ) == 1
    }

    private static func encodeFloat16(_ values: [Float]) throws -> (bytes: Data, norm: Double) {
        var encoded = [UInt16](repeating: 0, count: values.count)
        let encodeError = values.withUnsafeBytes { sourceBytes in
            encoded.withUnsafeMutableBytes { destinationBytes in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                    height: 1,
                    width: vImagePixelCount(values.count),
                    rowBytes: values.count * MemoryLayout<Float>.size
                )
                var destination = vImage_Buffer(
                    data: destinationBytes.baseAddress,
                    height: 1,
                    width: vImagePixelCount(values.count),
                    rowBytes: values.count * MemoryLayout<UInt16>.size
                )
                return vImageConvert_PlanarFtoPlanar16F(
                    &source,
                    &destination,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }
        guard encodeError == kvImageNoError else {
            throw ArchiveVectorStoreError.invalidRequest
        }
        let bytes = encoded.withUnsafeBytes { Data($0) }
        let decoded = try decodeFloat16(bytes, dimension: values.count)
        let norm = sqrt(decoded.reduce(0.0) { $0 + Double($1) * Double($1) })
        return (bytes, norm)
    }

    private static func decodeFloat16(_ data: Data, dimension: Int) throws -> [Float] {
        guard data.count == dimension * 2 else { throw ArchiveVectorStoreError.truncatedPayload }
        var decoded = [Float](repeating: 0, count: dimension)
        let decodeError = data.withUnsafeBytes { sourceBytes in
            decoded.withUnsafeMutableBytes { destinationBytes in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                    height: 1,
                    width: vImagePixelCount(dimension),
                    rowBytes: data.count
                )
                var destination = vImage_Buffer(
                    data: destinationBytes.baseAddress,
                    height: 1,
                    width: vImagePixelCount(dimension),
                    rowBytes: dimension * MemoryLayout<Float>.size
                )
                return vImageConvert_Planar16FtoPlanarF(
                    &source,
                    &destination,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }
        guard decodeError == kvImageNoError, decoded.allSatisfy(\.isFinite) else {
            throw ArchiveVectorStoreError.invalidRequest
        }
        return decoded
    }

    private static func writeInteger<T: FixedWidthInteger>(
        _ value: T,
        at offset: Int,
        into data: inout Data
    ) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) {
            data.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }

    private static func readInteger<T: FixedWidthInteger>(
        _ type: T.Type,
        _ data: Data,
        _ offset: Int
    ) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else { return nil }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<(offset + $0.count))
        }
        return T(littleEndian: value)
    }

    private static func uuid(_ data: Data.SubSequence) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

private struct VectorHeader {
    let dimension: Int
    let vectorByteCount: Int
    let modelHash: Data
    let producerHash: Data
    let preprocessingHash: Data
    let generation: UUID
}

private struct VectorRecord {
    let frameID: UUID
    let modelHash: String
    let byteOffset: Int64
    let dimension: Int
    let norm: Double
    let state: String
    let contentHash: Data
    let locator: String
}

private struct CompactionJournal: Codable {
    let modelHash: String
    let oldGeneration: UUID
    let newGeneration: UUID
    let backupName: String
}

extension Data {
    fileprivate var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    fileprivate init?(lowercaseHex: String) {
        guard lowercaseHex.count.isMultiple(of: 2),
            lowercaseHex.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
        else { return nil }
        var result = Data(capacity: lowercaseHex.count / 2)
        var index = lowercaseHex.startIndex
        while index < lowercaseHex.endIndex {
            let next = lowercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
