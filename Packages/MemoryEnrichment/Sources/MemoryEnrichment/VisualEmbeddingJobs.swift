import CryptoKit
import Foundation
import MemoryStore

public enum VisualEmbeddingJobError: Error, Equatable, Sendable {
    case invalidLease
    case sourceUnavailable
    case sourceIntegrityMismatch
    case sourceChanged
    case modelUnavailable
    case modelIdentityMismatch
    case invalidVector
    case publicationUnavailable
}

public enum VisualEmbeddingProducerIdentity {
    public static let jobVersion = "mobileclip-s0-coreml-3e0a7bf+image-v1"
    public static let preprocessingVersion = "srgb-aspectfill-bgra256-v1"

    public static func archiveVectorModel() throws -> ArchiveVectorModelIdentity {
        guard let modelHash = lowercaseHex(MobileCLIPRuntime.manifestSHA256) else {
            throw VisualEmbeddingJobError.modelIdentityMismatch
        }
        return try ArchiveVectorModelIdentity(
            modelHash: modelHash,
            jobVersion: jobVersion,
            producerName: "mobileclip-s0",
            producerSemanticVersion: "1.0.0+coreml.3e0a7bf.image-v1",
            preprocessingVersion: preprocessingVersion,
            dimension: MobileCLIPRuntime.dimension
        )
    }

    private static func lowercaseHex(_ encoded: String) -> Data? {
        guard encoded.count == 64,
            encoded.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
        else { return nil }
        var bytes = Data(capacity: 32)
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: 2)
            guard let byte = UInt8(encoded[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public struct VisualEmbeddingSource: Equatable, Sendable {
    public let frameID: UUID
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let policyGeneration: UInt64
    public let thumbnailPath: ArchiveRelativePath
    public let thumbnailHash: Data
    public let raster: ThumbnailRaster

    public init(
        frameID: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        policyGeneration: UInt64,
        thumbnailPath: ArchiveRelativePath,
        thumbnailHash: Data,
        raster: ThumbnailRaster
    ) {
        self.frameID = frameID
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.policyGeneration = policyGeneration
        self.thumbnailPath = thumbnailPath
        self.thumbnailHash = thumbnailHash
        self.raster = raster
    }
}

public protocol VisualEmbeddingSourceProviding: Sendable {
    func source(frameID: UUID) async throws -> VisualEmbeddingSource
    func revalidate(_ source: VisualEmbeddingSource) async throws
}

public struct VisualEmbeddingVector: Equatable, Sendable {
    public let values: [Float]
    public let contentHash: Data

    public init(rawValues: [Float], expectedDimension: Int = MobileCLIPRuntime.dimension) throws {
        guard rawValues.count == expectedDimension,
            rawValues.allSatisfy(\.isFinite)
        else {
            throw VisualEmbeddingJobError.invalidVector
        }
        var squaredNorm = 0.0
        for value in rawValues {
            squaredNorm += Double(value) * Double(value)
        }
        guard squaredNorm.isFinite, squaredNorm > 0 else {
            throw VisualEmbeddingJobError.invalidVector
        }
        let norm = sqrt(squaredNorm)
        let normalized = rawValues.map { Float(Double($0) / norm) }
        var normalizedSquaredNorm = 0.0
        for value in normalized {
            normalizedSquaredNorm += Double(value) * Double(value)
        }
        guard normalized.allSatisfy(\.isFinite),
            abs(sqrt(normalizedSquaredNorm) - 1) <= 0.000_01
        else {
            throw VisualEmbeddingJobError.invalidVector
        }
        values = normalized
        contentHash = Data(SHA256.hash(data: Self.canonicalBytes(normalized)))
    }

    public var norm: Double {
        sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
    }

    public var canonicalFloat32Bytes: Data {
        Self.canonicalBytes(values)
    }

    private static func canonicalBytes(_ values: [Float]) -> Data {
        var bytes = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }
}

public struct VisualEmbeddingPublication: Equatable, Sendable {
    public let jobID: UUID
    public let attemptCount: Int
    public let leaseExpiresAt: Date
    public let frameID: UUID
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let policyGeneration: UInt64
    public let producerVersion: String
    public let preprocessingVersion: String
    public let model: MobileCLIPModelDescriptor
    public let sourceHash: Data
    public let vector: VisualEmbeddingVector
}

public protocol VisualEmbeddingPublishing: Sendable {
    func publish(_ publication: VisualEmbeddingPublication) async throws
    func markSucceeded(_ lease: EnrichmentJobLease) async throws
    func markPermanentlyFailed(frameID: UUID, producerVersion: String) async throws
}

public actor VisualEmbeddingJobProcessor {
    private let sourceProvider: any VisualEmbeddingSourceProviding
    private let modelService: MobileCLIPModelService
    private let publisher: any VisualEmbeddingPublishing

    public init(
        sourceProvider: any VisualEmbeddingSourceProviding,
        modelService: MobileCLIPModelService,
        publisher: any VisualEmbeddingPublishing
    ) {
        self.sourceProvider = sourceProvider
        self.modelService = modelService
        self.publisher = publisher
    }

    @discardableResult
    public func process(_ lease: EnrichmentJobLease) async throws -> VisualEmbeddingPublication {
        guard lease.kind == .visualVector,
            lease.producerVersion == VisualEmbeddingProducerIdentity.jobVersion
        else {
            throw VisualEmbeddingJobError.invalidLease
        }
        let source: VisualEmbeddingSource
        do {
            source = try await sourceProvider.source(frameID: lease.parentID)
        } catch {
            throw VisualEmbeddingJobError.sourceUnavailable
        }
        guard source.frameID == lease.parentID else {
            throw VisualEmbeddingJobError.sourceChanged
        }
        try Task.checkCancellation()

        let availability = await modelService.start()
        guard case .ready(let descriptor) = availability else {
            throw VisualEmbeddingJobError.modelUnavailable
        }
        guard descriptor.version == MobileCLIPRuntime.version,
            descriptor.embeddingDimension == MobileCLIPRuntime.dimension,
            descriptor.manifestSHA256 == MobileCLIPRuntime.manifestSHA256
        else {
            throw VisualEmbeddingJobError.modelIdentityMismatch
        }
        let rawValues: [Float]
        do {
            rawValues = try await modelService.embed(raster: source.raster)
        } catch {
            throw VisualEmbeddingJobError.modelUnavailable
        }
        try Task.checkCancellation()
        let vector = try VisualEmbeddingVector(
            rawValues: rawValues,
            expectedDimension: descriptor.embeddingDimension
        )
        do {
            try await sourceProvider.revalidate(source)
        } catch {
            throw VisualEmbeddingJobError.sourceChanged
        }
        try Task.checkCancellation()

        let publication = VisualEmbeddingPublication(
            jobID: lease.jobID,
            attemptCount: lease.attemptCount,
            leaseExpiresAt: lease.expiresAt,
            frameID: source.frameID,
            captureEpochID: source.captureEpochID,
            targetWindowID: source.targetWindowID,
            policyGeneration: source.policyGeneration,
            producerVersion: lease.producerVersion,
            preprocessingVersion: VisualEmbeddingProducerIdentity.preprocessingVersion,
            model: descriptor,
            sourceHash: source.thumbnailHash,
            vector: vector
        )
        do {
            try await publisher.publish(publication)
        } catch {
            throw VisualEmbeddingJobError.publicationUnavailable
        }
        return publication
    }

    public func markPermanentlyFailed(_ lease: EnrichmentJobLease) async throws {
        try await publisher.markPermanentlyFailed(
            frameID: lease.parentID,
            producerVersion: lease.producerVersion
        )
    }
}

public actor VisualEmbeddingJobRunner {
    private let scheduler: EnrichmentScheduler
    private let conditions: any EnrichmentRuntimeConditionProviding
    private let processor: VisualEmbeddingJobProcessor

    public init(
        scheduler: EnrichmentScheduler,
        conditions: any EnrichmentRuntimeConditionProviding,
        processor: VisualEmbeddingJobProcessor
    ) {
        self.scheduler = scheduler
        self.conditions = conditions
        self.processor = processor
    }

    public func runNext(now: Date) async throws -> EnrichmentSchedulerOutcome {
        let currentConditions = await conditions.currentConditions()
        let processor = processor
        let outcome = try await scheduler.runNext(
            conditions: currentConditions,
            now: now
        ) { lease in
            try await processor.process(lease)
        }
        if case .permanentlyFailed(let lease) = outcome {
            try await processor.markPermanentlyFailed(lease)
        } else if case .succeeded(let lease) = outcome {
            try await processor.markSucceeded(lease)
        }
        return outcome
    }
}

extension VisualEmbeddingJobProcessor {
    public func markSucceeded(_ lease: EnrichmentJobLease) async throws {
        try await publisher.markSucceeded(lease)
    }
}

public actor ArchiveVisualEmbeddingPublisher: VisualEmbeddingPublishing {
    private let vectorStore: ArchiveVectorStore
    private let visualStore: ArchiveVisualEmbeddingStore
    private let model: ArchiveVectorModelIdentity

    public init(database: ArchiveDatabase) throws {
        vectorStore = try ArchiveVectorStore(database: database)
        visualStore = ArchiveVisualEmbeddingStore(database: database)
        model = try VisualEmbeddingProducerIdentity.archiveVectorModel()
    }

    public func publish(_ publication: VisualEmbeddingPublication) async throws {
        guard publication.producerVersion == model.jobVersion,
            publication.preprocessingVersion == model.preprocessingVersion,
            publication.model.manifestSHA256 == model.modelHashHex,
            publication.model.embeddingDimension == model.dimension
        else {
            throw VisualEmbeddingJobError.modelIdentityMismatch
        }
        let lease = EnrichmentJobLease(
            jobID: publication.jobID,
            parentID: publication.frameID,
            kind: .visualVector,
            priority: EnrichmentJobPriority.visualEmbedding,
            attemptCount: publication.attemptCount,
            producerVersion: publication.producerVersion,
            expiresAt: publication.leaseExpiresAt
        )
        do {
            _ = try vectorStore.stage(
                ArchiveVectorAppendRequest(
                    lease: lease,
                    captureEpochID: publication.captureEpochID,
                    targetWindowID: publication.targetWindowID,
                    policyGeneration: publication.policyGeneration,
                    sourceHash: publication.sourceHash,
                    model: model,
                    values: publication.vector.values
                )
            )
        } catch {
            throw VisualEmbeddingJobError.publicationUnavailable
        }
    }

    public func markSucceeded(_ lease: EnrichmentJobLease) async throws {
        do {
            try vectorStore.finalize(lease, model: model)
        } catch {
            throw VisualEmbeddingJobError.publicationUnavailable
        }
    }

    public func markPermanentlyFailed(frameID: UUID, producerVersion: String) async throws {
        try visualStore.markPermanentlyFailed(
            frameID: frameID,
            producerVersion: producerVersion
        )
    }

    public func recover() async throws -> ArchiveVectorRecoveryReport {
        try vectorStore.recover(model: model)
    }

}

public final class ArchiveVisualEmbeddingSourceProvider: @unchecked Sendable,
    VisualEmbeddingSourceProviding
{
    private let metadataStore: ArchiveVisualEmbeddingStore
    private let fileStore: ArchiveFileStore
    private let decoder: any ThumbnailHEICDecoding
    private let fileManager: FileManager

    public init(
        metadataStore: ArchiveVisualEmbeddingStore,
        fileStore: ArchiveFileStore,
        decoder: any ThumbnailHEICDecoding,
        fileManager: FileManager = .default
    ) {
        self.metadataStore = metadataStore
        self.fileStore = fileStore
        self.decoder = decoder
        self.fileManager = fileManager
    }

    public func source(frameID: UUID) async throws -> VisualEmbeddingSource {
        let record = try metadataStore.readyThumbnail(frameID: frameID)
        let url = fileStore.url(for: record.thumbnailPath)
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            fileManager.fileExists(atPath: url.path)
        else {
            throw VisualEmbeddingJobError.sourceUnavailable
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Data(SHA256.hash(data: bytes)) == record.thumbnailHash else {
            throw VisualEmbeddingJobError.sourceIntegrityMismatch
        }
        let decoded = try decoder.decode(bytes)
        let raster = try ThumbnailRasterizer().render(decoded)
        try metadataStore.revalidate(record)
        return VisualEmbeddingSource(
            frameID: record.frameID,
            captureEpochID: record.captureEpochID,
            targetWindowID: record.targetWindowID,
            policyGeneration: record.policyGeneration,
            thumbnailPath: record.thumbnailPath,
            thumbnailHash: record.thumbnailHash,
            raster: raster
        )
    }

    public func revalidate(_ source: VisualEmbeddingSource) async throws {
        let expected = ArchiveVisualEmbeddingSourceRecord(
            frameID: source.frameID,
            captureEpochID: source.captureEpochID,
            targetWindowID: source.targetWindowID,
            policyGeneration: source.policyGeneration,
            thumbnailPath: source.thumbnailPath,
            thumbnailHash: source.thumbnailHash
        )
        try metadataStore.revalidate(expected)
    }
}
