import Foundation
import GRDB

public struct ArchiveCaptureIdentity: Equatable, Sendable {
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let policyGeneration: UInt64

    public init(captureEpochID: UUID, targetWindowID: UInt32, policyGeneration: UInt64) {
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.policyGeneration = policyGeneration
    }
}

public struct ArchiveCaptureAuthorization: Equatable, Sendable {
    public let identity: ArchiveCaptureIdentity
    public let isAllowed: Bool

    public init(identity: ArchiveCaptureIdentity, isAllowed: Bool) {
        self.identity = identity
        self.isAllowed = isAllowed
    }
}

public struct ArchiveFrameProjection: Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let monotonicNanoseconds: UInt64
    public let presentationTimeMilliseconds: Int64
    public let captureReason: String
    public let isTransition: Bool
    public let bundleIdentifier: String?
    public let applicationName: String?
    public let windowTitle: String?
    public let mediaPath: String

    public init(
        id: UUID,
        capturedAt: Date,
        monotonicNanoseconds: UInt64,
        presentationTimeMilliseconds: Int64,
        captureReason: String,
        isTransition: Bool,
        bundleIdentifier: String?,
        applicationName: String?,
        windowTitle: String?,
        mediaPath: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.monotonicNanoseconds = monotonicNanoseconds
        self.presentationTimeMilliseconds = presentationTimeMilliseconds
        self.captureReason = captureReason
        self.isTransition = isTransition
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.mediaPath = mediaPath
    }
}

public struct ArchiveRetryableJob: Equatable, Sendable {
    public let id: UUID
    public let frameID: UUID
    public let kind: String
    public let priority: Int
    public let producerVersion: String

    public init(
        id: UUID,
        frameID: UUID,
        kind: String,
        priority: Int,
        producerVersion: String
    ) {
        self.id = id
        self.frameID = frameID
        self.kind = kind
        self.priority = priority
        self.producerVersion = producerVersion
    }
}

public enum ArchiveAtomicCoordinatorFault: String, Codable, Equatable, Sendable {
    case afterVerification
    case duringTransaction
    case afterCommit
}

public enum ArchiveAtomicCoordinatorError: Error, Equatable, Sendable {
    case fileBackedArchiveRequired
    case deniedAuthorization
    case invalidCaptureIdentity
    case staleCaptureIdentity
    case manifestIdentityMismatch
    case frameInventoryMismatch
    case frameLocatorMismatch
    case invalidJob
    case injectedCrash(ArchiveAtomicCoordinatorFault)
}

public struct ArchiveAtomicCommitResult: Equatable, Sendable {
    public let chunkID: UUID
    public let committedFrameCount: Int
    public let queuedJobCount: Int
}

public final class ArchiveAtomicCoordinator: @unchecked Sendable {
    private let database: ArchiveDatabase
    private let paths: ArchivePaths
    private let fileManager: FileManager

    public init(database: ArchiveDatabase, fileManager: FileManager = .default) throws {
        guard let paths = database.paths else {
            throw ArchiveAtomicCoordinatorError.fileBackedArchiveRequired
        }
        self.database = database
        self.paths = paths
        self.fileManager = fileManager
    }

    public func commit(
        manifestRelativePath: ArchiveRelativePath,
        authorization: ArchiveCaptureAuthorization,
        frames: [ArchiveFrameProjection],
        jobs: [ArchiveRetryableJob],
        fault: ArchiveAtomicCoordinatorFault? = nil,
        currentIdentity: @Sendable () throws -> ArchiveCaptureIdentity
    ) throws -> ArchiveAtomicCommitResult {
        guard authorization.isAllowed else {
            throw ArchiveAtomicCoordinatorError.deniedAuthorization
        }
        let identity = authorization.identity
        guard identity.targetWindowID > 0, identity.policyGeneration > 0,
            identity.policyGeneration <= UInt64(Int64.max)
        else {
            throw ArchiveAtomicCoordinatorError.invalidCaptureIdentity
        }

        let verified = try verify(manifestRelativePath, identity: identity)
        try validate(frames: frames, jobs: jobs, against: verified)
        guard try currentIdentity() == identity else {
            throw ArchiveAtomicCoordinatorError.staleCaptureIdentity
        }
        if fault == .afterVerification {
            throw ArchiveAtomicCoordinatorError.injectedCrash(.afterVerification)
        }

        guard let firstFrame = frames.first, let lastFrame = frames.last,
            lastFrame.capturedAt.timeIntervalSince(firstFrame.capturedAt) + 0.001 <= 30
        else {
            throw ArchiveAtomicCoordinatorError.frameLocatorMismatch
        }
        let startedAt = firstFrame.capturedAt
        let endedAt = lastFrame.capturedAt.addingTimeInterval(0.001)
        let committedVerification = try database.atomicWrite { database in
            guard try currentIdentity() == identity else {
                throw ArchiveAtomicCoordinatorError.staleCaptureIdentity
            }
            let transactionVerified = try verify(manifestRelativePath, identity: identity)
            try validate(frames: frames, jobs: jobs, against: transactionVerified)
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, ?, ?, ?, ?, 'heicKeyframes', ?, ?, ?, ?, ?, 'ready')
                    """,
                arguments: [
                    transactionVerified.manifest.chunkID.uuidString.lowercased(),
                    identity.captureEpochID.uuidString.lowercased(),
                    identity.targetWindowID,
                    manifestRelativePath.rawValue,
                    Self.encode(startedAt),
                    Self.encode(endedAt),
                    transactionVerified.manifest.width,
                    transactionVerified.manifest.height,
                    transactionVerified.frames.count,
                    transactionVerified.totalByteCount,
                    Self.hex(transactionVerified.manifestSHA256),
                ]
            )
            for (projection, source) in zip(frames, transactionVerified.frames) {
                try database.execute(
                    sql: """
                        INSERT INTO frames(
                            id, captured_at, monotonic_ns, capture_epoch_id,
                            target_window_id, chunk_id, pts_ms, media_path,
                            media_sha256, media_byte_count, bundle_id, app_name,
                            window_title, capture_reason, is_transition, text_state,
                            visual_state, schema_version, approved_text, policy_generation
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                                  'pending', 'pending', 2, '', ?)
                        """,
                    arguments: [
                        projection.id.uuidString.lowercased(),
                        Self.encode(projection.capturedAt),
                        Int64(projection.monotonicNanoseconds),
                        identity.captureEpochID.uuidString.lowercased(),
                        identity.targetWindowID,
                        transactionVerified.manifest.chunkID.uuidString.lowercased(),
                        source.presentationTimeMilliseconds,
                        source.archiveRelativePath,
                        Self.hex(source.sha256),
                        source.byteCount,
                        projection.bundleIdentifier,
                        projection.applicationName,
                        projection.windowTitle,
                        projection.captureReason,
                        projection.isTransition ? 1 : 0,
                        identity.policyGeneration,
                    ]
                )
            }
            for job in jobs {
                try database.execute(
                    sql: """
                        INSERT INTO processing_jobs(
                            id, parent_id, kind, priority, state, attempts,
                            next_attempt_at, producer_version, error_code, lease_expires_at
                        ) VALUES (?, ?, ?, ?, 'queued', 0, NULL, ?, NULL, NULL)
                        """,
                    arguments: [
                        job.id.uuidString.lowercased(),
                        job.frameID.uuidString.lowercased(),
                        job.kind,
                        job.priority,
                        job.producerVersion,
                    ]
                )
            }
            if fault == .duringTransaction {
                throw ArchiveAtomicCoordinatorError.injectedCrash(.duringTransaction)
            }
            return transactionVerified
        }

        if fault == .afterCommit {
            throw ArchiveAtomicCoordinatorError.injectedCrash(.afterCommit)
        }
        return ArchiveAtomicCommitResult(
            chunkID: committedVerification.manifest.chunkID,
            committedFrameCount: committedVerification.frames.count,
            queuedJobCount: jobs.count
        )
    }

    private func verify(
        _ manifestRelativePath: ArchiveRelativePath,
        identity: ArchiveCaptureIdentity
    ) throws -> ArchiveVerifiedHEICChunk {
        do {
            return try ArchiveHEICChunkVerifier.verify(
                paths: paths,
                manifestRelativePath: manifestRelativePath,
                expectedCaptureEpochID: identity.captureEpochID,
                expectedTargetWindowID: identity.targetWindowID,
                fileManager: fileManager
            )
        } catch ArchiveHEICVerificationError.captureIdentityMismatch {
            throw ArchiveAtomicCoordinatorError.manifestIdentityMismatch
        }
    }

    private func validate(
        frames: [ArchiveFrameProjection],
        jobs: [ArchiveRetryableJob],
        against verified: ArchiveVerifiedHEICChunk
    ) throws {
        guard frames.map(\.id) == verified.frames.map(\.id),
            Set(frames.map(\.id)).count == frames.count
        else {
            throw ArchiveAtomicCoordinatorError.frameInventoryMismatch
        }
        for (projection, source) in zip(frames, verified.frames) {
            guard projection.presentationTimeMilliseconds == source.presentationTimeMilliseconds,
                projection.mediaPath == source.archiveRelativePath,
                projection.monotonicNanoseconds <= UInt64(Int64.max),
                !projection.captureReason.isEmpty
            else {
                throw ArchiveAtomicCoordinatorError.frameLocatorMismatch
            }
        }
        guard
            zip(frames, frames.dropFirst()).allSatisfy({
                $0.capturedAt < $1.capturedAt
                    && $0.monotonicNanoseconds < $1.monotonicNanoseconds
            })
        else {
            throw ArchiveAtomicCoordinatorError.frameLocatorMismatch
        }
        let frameIDs = Set(frames.map(\.id))
        let supportedJobKinds: Set<String> = [
            "accessibilityText", "accessibility-text",
            "visionOCR", "vision-ocr",
            "thumbnail",
            "visualVector", "visual-vector",
            "transcription",
            "mediaRewrite", "media-rewrite",
            "vectorCompaction", "vector-compaction",
        ]
        guard Set(jobs.map(\.id)).count == jobs.count,
            jobs.allSatisfy({
                frameIDs.contains($0.frameID)
                    && supportedJobKinds.contains($0.kind)
                    && (0...1_000).contains($0.priority)
                    && $0.producerVersion.range(
                        of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$",
                        options: .regularExpression
                    ) != nil
            })
        else {
            throw ArchiveAtomicCoordinatorError.invalidJob
        }
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
