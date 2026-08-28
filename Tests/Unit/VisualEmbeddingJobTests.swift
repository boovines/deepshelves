import CryptoKit
import Foundation
import GRDB
import MemoryContracts
import XCTest

@testable import MemoryEnrichment
@testable import MemoryStore

final class VisualEmbeddingJobTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_900_000)

    func testFrozenVectorNormalizationIsStableAndRejectsInvalidOutput() throws {
        let fixture = try frozenFixture()
        let raw = fixture.inputPrefix + [Float](repeating: 0, count: fixture.dimension - 2)

        let vector = try VisualEmbeddingVector(rawValues: raw)

        XCTAssertEqual(Array(vector.values.prefix(2)), fixture.normalizedPrefix)
        XCTAssertEqual(vector.norm, fixture.expectedNorm, accuracy: 1e-7)
        XCTAssertEqual(vector.canonicalFloat32Bytes.count, 2_048)
        XCTAssertEqual(vector.contentHash.hex, fixture.canonicalFloat32SHA256)
        XCTAssertThrowsError(try VisualEmbeddingVector(rawValues: [0, 0]))
        XCTAssertThrowsError(
            try VisualEmbeddingVector(
                rawValues: [Float.nan] + [Float](repeating: 0, count: 511)
            )
        )
        XCTAssertThrowsError(
            try VisualEmbeddingVector(rawValues: [Float](repeating: 0, count: 512))
        )
    }

    func testProcessorPublishesExactIdentityAndNormalizedVectorOnce() async throws {
        let frameID = UUID()
        let runtime = FixtureEmbeddingRuntime(output: fixtureRawVector)
        let descriptor = productionDescriptor
        let service = MobileCLIPModelService {
            MobileCLIPLoadedRuntime(descriptor: descriptor, runtime: runtime)
        }
        let sourceProvider = FixtureVisualSourceProvider(source: try fixtureSource(id: frameID))
        let publisher = FixtureVisualPublisher()
        let processor = VisualEmbeddingJobProcessor(
            sourceProvider: sourceProvider,
            modelService: service,
            publisher: publisher
        )
        let lease = fixtureLease(attempt: 1, parentID: frameID)

        let publication = try await processor.process(lease)

        XCTAssertEqual(publication.jobID, lease.jobID)
        XCTAssertEqual(publication.frameID, lease.parentID)
        XCTAssertEqual(publication.producerVersion, VisualEmbeddingProducerIdentity.jobVersion)
        XCTAssertEqual(
            publication.preprocessingVersion,
            VisualEmbeddingProducerIdentity.preprocessingVersion
        )
        XCTAssertEqual(publication.vector.contentHash.hex, frozenVectorHash)
        XCTAssertEqual(publication.vector.norm, 1, accuracy: 1e-7)
        let publications = await publisher.publications
        let runtimeCalls = await runtime.imageCalls
        let revalidations = await sourceProvider.revalidationCount
        XCTAssertEqual(publications, [publication])
        XCTAssertEqual(runtimeCalls, 1)
        XCTAssertEqual(revalidations, 1)
    }

    func testRunnerDefersVisualWorkForCaptureThermalAndPowerWithoutLeasing() async throws {
        let database = try ArchiveDatabase.deterministicTestStore()
        let store = try ArchiveEnrichmentJobStore(database: database)
        let jobID = UUID()
        let frameID = UUID()
        try store.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: frameID,
                kind: .visualVector,
                priority: EnrichmentJobPriority.visualEmbedding,
                producerVersion: VisualEmbeddingProducerIdentity.jobVersion
            )
        )
        let runtime = FixtureEmbeddingRuntime(output: fixtureRawVector)
        let descriptor = productionDescriptor
        let publisher = FixtureVisualPublisher()
        let conditions = MutableEmbeddingConditions(
            value: runtimeConditions(capturePending: true)
        )
        let runner = VisualEmbeddingJobRunner(
            scheduler: EnrichmentScheduler(
                store: store,
                producerVersions: [
                    .visualVector: VisualEmbeddingProducerIdentity.jobVersion
                ]
            ),
            conditions: conditions,
            processor: VisualEmbeddingJobProcessor(
                sourceProvider: FixtureVisualSourceProvider(source: try fixtureSource(id: frameID)),
                modelService: MobileCLIPModelService {
                    MobileCLIPLoadedRuntime(
                        descriptor: descriptor,
                        runtime: runtime
                    )
                },
                publisher: publisher
            )
        )

        var outcome = try await runner.runNext(now: now)
        XCTAssertEqual(outcome, .deferred(.captureTransitionPending))
        await conditions.set(runtimeConditions(thermal: .serious))
        outcome = try await runner.runNext(now: now)
        XCTAssertEqual(outcome, .deferred(.noEligibleWork))
        await conditions.set(runtimeConditions(lowPower: true))
        outcome = try await runner.runNext(now: now)
        XCTAssertEqual(outcome, .deferred(.noEligibleWork))
        await conditions.set(runtimeConditions(power: .battery, battery: 0.20))
        outcome = try await runner.runNext(now: now)
        XCTAssertEqual(outcome, .deferred(.noEligibleWork))
        await conditions.set(runtimeConditions(thermal: .critical))
        outcome = try await runner.runNext(now: now)
        XCTAssertEqual(outcome, .deferred(.thermalPressure))
        XCTAssertEqual(try XCTUnwrap(try store.job(jobID)).attemptCount, 0)

        await conditions.set(runtimeConditions())
        guard case .succeeded(let lease) = try await runner.runNext(now: now) else {
            return XCTFail("normal conditions should run the visual job")
        }
        XCTAssertEqual(lease.attemptCount, 1)
        let backlog = try store.backlog(now: now)
        XCTAssertEqual(backlog.totalPending, 0)
        XCTAssertEqual(backlog.presentation.visualPendingCount, 0)
        XCTAssertEqual(backlog.presentation.visualStatusText, "Visual search up to date")
        let imageCalls = await runtime.imageCalls
        XCTAssertEqual(imageCalls, 1)
    }

    func testFailedEmbeddingRetriesThreeTimesThenMarksVisualFailure() async throws {
        let store = try ArchiveEnrichmentJobStore(
            database: ArchiveDatabase.deterministicTestStore()
        )
        let frameID = UUID()
        let jobID = UUID()
        try store.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: frameID,
                kind: .visualVector,
                priority: EnrichmentJobPriority.visualEmbedding,
                producerVersion: VisualEmbeddingProducerIdentity.jobVersion
            )
        )
        let publisher = FixtureVisualPublisher()
        let runner = VisualEmbeddingJobRunner(
            scheduler: EnrichmentScheduler(
                store: store,
                producerVersions: [
                    .visualVector: VisualEmbeddingProducerIdentity.jobVersion
                ]
            ),
            conditions: MutableEmbeddingConditions(value: runtimeConditions()),
            processor: VisualEmbeddingJobProcessor(
                sourceProvider: FixtureVisualSourceProvider(source: try fixtureSource(id: frameID)),
                modelService: MobileCLIPModelService {
                    throw ModelResourceError.hashMismatch("model")
                },
                publisher: publisher
            )
        )

        var attemptTime = now
        for attempt in 1...3 {
            let outcome = try await runner.runNext(now: attemptTime)
            if attempt < 3 {
                guard case .retryScheduled(let lease, let retryAt) = outcome else {
                    return XCTFail("attempt \(attempt) should retry")
                }
                XCTAssertEqual(lease.attemptCount, attempt)
                attemptTime = retryAt.addingTimeInterval(0.001)
            } else {
                guard case .permanentlyFailed(let lease) = outcome else {
                    return XCTFail("third attempt should fail permanently")
                }
                XCTAssertEqual(lease.attemptCount, 3)
            }
        }

        let failures = await publisher.permanentFailures
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].frameID, frameID)
        XCTAssertEqual(failures[0].producerVersion, VisualEmbeddingProducerIdentity.jobVersion)
        XCTAssertEqual(try XCTUnwrap(try store.job(jobID)).state, .permanentFailure)
    }

    func testProducerInvalidationStalesVectorProjectionAndPreservesSuppression() throws {
        let database = try ArchiveDatabase.deterministicTestStore()
        let firstFrame = UUID()
        let secondFrame = UUID()
        try seedArchive(
            database,
            frameID: firstFrame,
            jobVersion: "mobileclip-old",
            visualState: "ready"
        )
        try seedArchive(
            database,
            frameID: secondFrame,
            jobVersion: "mobileclip-old",
            visualState: "suppressed"
        )
        let jobs = try ArchiveEnrichmentJobStore(database: database)
        let visual = ArchiveVisualEmbeddingStore(database: database)

        let invalidated = try jobs.synchronizeProducerVersions([
            .visualVector: VisualEmbeddingProducerIdentity.jobVersion
        ])

        XCTAssertEqual(invalidated, 2)
        XCTAssertEqual(
            try jobs.synchronizeProducerVersions([
                .visualVector: VisualEmbeddingProducerIdentity.jobVersion
            ]), 0)
        let first = try visual.stateForTesting(frameID: firstFrame)
        XCTAssertEqual(first.frameState, "pending")
        XCTAssertEqual(first.artifactStates, ["stale"])
        XCTAssertEqual(first.vectorState, "stale")
        let second = try visual.stateForTesting(frameID: secondFrame)
        XCTAssertEqual(second.frameState, "suppressed")
        XCTAssertEqual(second.artifactStates, ["stale"])
        XCTAssertEqual(second.vectorState, "stale")
    }

    func testArchiveSourceProviderVerifiesHashAndFailsClosedAfterSuppression() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(
            path: "lm050-source-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let database = try ArchiveDatabase(
            applicationSupportDirectory: temporary,
            encryptionKey: Data(repeating: 9, count: 32)
        )
        let frameID = UUID()
        let thumbnailBytes = Data("software thumbnail fixture".utf8)
        let thumbnailHash = Data(SHA256.hash(data: thumbnailBytes))
        try seedArchive(
            database,
            frameID: frameID,
            jobVersion: VisualEmbeddingProducerIdentity.jobVersion,
            visualState: "pending",
            thumbnailHash: thumbnailHash.hex
        )
        let fileStore = try XCTUnwrap(database.fileStore)
        let path = try ArchiveRelativePath(
            "thumbnails/2026/08/29/\(frameID.uuidString.lowercased()).heic"
        )
        _ = try fileStore.write(thumbnailBytes, to: path)
        let metadata = ArchiveVisualEmbeddingStore(database: database)
        let provider = ArchiveVisualEmbeddingSourceProvider(
            metadataStore: metadata,
            fileStore: fileStore,
            decoder: FixtureThumbnailDecoder(raster: try fixtureRaster())
        )

        let source = try await provider.source(frameID: frameID)
        XCTAssertEqual(source.frameID, frameID)
        XCTAssertEqual(source.thumbnailHash, thumbnailHash)
        XCTAssertEqual(source.raster.colorSpace, .sRGB)

        try database.atomicWrite { database in
            try database.execute(
                sql: "UPDATE frames SET visual_state = 'suppressed' WHERE id = ?",
                arguments: [frameID.uuidString.lowercased()]
            )
        }
        do {
            try await provider.revalidate(source)
            XCTFail("suppressed source must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ArchiveVisualEmbeddingStoreError,
                .sourceUnavailable
            )
        }
    }

    private var fixtureRawVector: [Float] {
        [3, 4] + [Float](repeating: 0, count: 510)
    }

    private var frozenVectorHash: String {
        "2cdd74c082e797454606fd2bd5ac4852cb42e0081ffc90c1890bbc25b24c8065"
    }

    private var productionDescriptor: MobileCLIPModelDescriptor {
        MobileCLIPModelDescriptor(
            verifiedResources: VerifiedModelResources(
                version: MobileCLIPRuntime.version,
                manifestSHA256: MobileCLIPRuntime.manifestSHA256,
                artifactCount: MobileCLIPRuntime.artifactCount,
                bundledFootprintBytes: MobileCLIPRuntime.bundledFootprintBytes
            )
        )
    }

    private func fixtureSource(id: UUID = UUID()) throws -> VisualEmbeddingSource {
        try VisualEmbeddingSource(
            frameID: id,
            captureEpochID: UUID(),
            targetWindowID: 42,
            policyGeneration: 7,
            thumbnailPath: ArchiveRelativePath(
                "thumbnails/2026/08/29/\(id.uuidString.lowercased()).heic"
            ),
            thumbnailHash: Data(repeating: 4, count: 32),
            raster: fixtureRaster()
        )
    }

    private func fixtureRaster() throws -> ThumbnailRaster {
        try ThumbnailRaster(
            width: 2,
            height: 2,
            rgba8: [
                255, 0, 0, 255, 0, 255, 0, 255,
                0, 0, 255, 255, 255, 255, 255, 255,
            ],
            colorSpace: .sRGB
        )
    }

    private func fixtureLease(attempt: Int, parentID: UUID = UUID()) -> EnrichmentJobLease {
        EnrichmentJobLease(
            jobID: UUID(),
            parentID: parentID,
            kind: .visualVector,
            priority: EnrichmentJobPriority.visualEmbedding,
            attemptCount: attempt,
            producerVersion: VisualEmbeddingProducerIdentity.jobVersion,
            expiresAt: now.addingTimeInterval(120)
        )
    }

    private func runtimeConditions(
        capturePending: Bool = false,
        thermal: EnrichmentThermalState = .nominal,
        lowPower: Bool = false,
        power: EnrichmentPowerSource = .external,
        battery: Double? = nil
    ) -> EnrichmentRuntimeConditions {
        EnrichmentRuntimeConditions(
            isUserIdle: false,
            powerSource: power,
            batteryLevel: battery,
            lowPowerModeEnabled: lowPower,
            thermalState: thermal,
            captureTransitionPending: capturePending
        )
    }

    private func frozenFixture() throws -> FrozenVisualVectorFixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            FrozenVisualVectorFixture.self,
            from: Data(
                contentsOf: root.appending(path: "Fixtures/LM050/visual-embedding-golden.json"))
        )
    }

    private func seedArchive(
        _ archive: ArchiveDatabase,
        frameID: UUID,
        jobVersion: String,
        visualState: String,
        thumbnailHash: String = String(repeating: "a", count: 64)
    ) throws {
        let frame = frameID.uuidString.lowercased()
        let epoch = UUID().uuidString.lowercased()
        let chunk = UUID().uuidString.lowercased()
        let thumbnail = "thumbnails/2026/08/29/\(frame).heic"
        let media = "media/2026/08/29/\(chunk)/frames/\(frame).heic"
        try archive.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, 42, ?, '2026-08-29T00:00:00.000Z',
                              '2026-08-29T00:00:01.000Z', 'heicKeyframes', 256, 256,
                              1, 128, ?, 'ready')
                    """,
                arguments: [
                    chunk, epoch, "media/2026/08/29/\(chunk)/manifest.json",
                    String(repeating: "b", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, media_path,
                        media_sha256, media_byte_count, thumbnail_path,
                        capture_reason, is_transition, text_state, visual_state,
                        schema_version, approved_text, policy_generation
                    ) VALUES (?, '2026-08-29T00:00:00.500Z', 500000000, ?, 42, ?,
                              500, ?, ?, 128, ?, 'visualChange', 0, 'ready', ?, 2, '', 7)
                    """,
                arguments: [
                    frame, epoch, chunk, media, String(repeating: "c", count: 64),
                    thumbnail, visualState,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO artifacts(
                        id, frame_id, kind, producer_name, producer_version,
                        model_hash, locator_kind, locator_value, content_hash, state
                    ) VALUES (?, ?, 'thumbnail', 'thumbnail', '1.0.0', NULL,
                              'relativeFileOffset', ?, ?, 'ready')
                    """,
                arguments: [UUID().uuidString.lowercased(), frame, thumbnail, thumbnailHash]
            )
            try database.execute(
                sql: """
                    INSERT INTO artifacts(
                        id, frame_id, kind, producer_name, producer_version,
                        model_hash, locator_kind, locator_value, content_hash, state
                    ) VALUES (?, ?, 'visualVector', 'mobileclip', '1.0.0', ?,
                              'relativeFileOffset', 'vectors/old.f16:0', ?, 'ready')
                    """,
                arguments: [
                    UUID().uuidString.lowercased(), frame,
                    String(repeating: "d", count: 64),
                    String(repeating: "e", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO vector_offsets(
                        frame_id, model_hash, byte_offset, dimension, norm, state
                    ) VALUES (?, ?, 0, 512, 1.0, 'ready')
                    """,
                arguments: [frame, String(repeating: "d", count: 64)]
            )
            try database.execute(
                sql: """
                    INSERT INTO processing_jobs(
                        id, parent_id, kind, priority, state, attempts,
                        next_attempt_at, producer_version, error_code, lease_expires_at
                    ) VALUES (?, ?, 'visualVector', 500, 'succeeded', 1,
                              NULL, ?, NULL, NULL)
                    """,
                arguments: [UUID().uuidString.lowercased(), frame, jobVersion]
            )
        }
    }
}

private struct FrozenVisualVectorFixture: Decodable {
    let dimension: Int
    let inputPrefix: [Float]
    let normalizedPrefix: [Float]
    let expectedNorm: Double
    let canonicalFloat32SHA256: String
}

private actor FixtureEmbeddingRuntime: MobileCLIPEmbeddingRuntime {
    let output: [Float]
    private(set) var imageCalls = 0

    init(output: [Float]) {
        self.output = output
    }

    func embed(text _: String) async throws -> [Float] {
        output
    }

    func embed(raster _: ThumbnailRaster) async throws -> [Float] {
        imageCalls += 1
        return output
    }
}

private actor FixtureVisualSourceProvider: VisualEmbeddingSourceProviding {
    let sourceValue: VisualEmbeddingSource
    private(set) var revalidationCount = 0

    init(source: VisualEmbeddingSource) {
        sourceValue = source
    }

    func source(frameID: UUID) async throws -> VisualEmbeddingSource {
        guard frameID == sourceValue.frameID else {
            throw VisualEmbeddingJobError.sourceUnavailable
        }
        return sourceValue
    }

    func revalidate(_ source: VisualEmbeddingSource) async throws {
        guard source == sourceValue else {
            throw VisualEmbeddingJobError.sourceChanged
        }
        revalidationCount += 1
    }
}

private actor FixtureVisualPublisher: VisualEmbeddingPublishing {
    struct Failure: Equatable {
        let frameID: UUID
        let producerVersion: String
    }

    private(set) var publications: [VisualEmbeddingPublication] = []
    private(set) var permanentFailures: [Failure] = []

    func publish(_ publication: VisualEmbeddingPublication) async throws {
        publications.append(publication)
    }

    func markPermanentlyFailed(frameID: UUID, producerVersion: String) async throws {
        permanentFailures.append(Failure(frameID: frameID, producerVersion: producerVersion))
    }
}

private actor MutableEmbeddingConditions: EnrichmentRuntimeConditionProviding {
    private var value: EnrichmentRuntimeConditions

    init(value: EnrichmentRuntimeConditions) {
        self.value = value
    }

    func currentConditions() async -> EnrichmentRuntimeConditions {
        value
    }

    func set(_ value: EnrichmentRuntimeConditions) {
        self.value = value
    }
}

private struct FixtureThumbnailDecoder: ThumbnailHEICDecoding {
    let raster: ThumbnailRaster

    func decode(_: Data) throws -> ThumbnailSourceImage {
        try ThumbnailSourceImage(raster: raster, orientation: .up)
    }
}

extension Data {
    fileprivate var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
