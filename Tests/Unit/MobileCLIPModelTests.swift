import Foundation
import MemoryEnrichment
import XCTest

final class MobileCLIPModelTests: XCTestCase {
    func testPinnedBundleVerificationReproducesS3PackageIdentity() throws {
        let verified = try MobileCLIPRuntime.verifyBundledResources()

        XCTAssertEqual(verified.version, "mobileclip-s0-coreml-3e0a7bf")
        XCTAssertEqual(
            verified.manifestSHA256,
            "758468b14a34070a0f6295fe8b6fd4d1b8cf536083cbb10c847fd5dae3cc762b"
        )
        XCTAssertEqual(verified.artifactCount, 12)
        XCTAssertEqual(verified.bundledFootprintBytes, 112_239_644)
    }

    func testPinnedManifestRejectsCorruptArtifactEvenWhenManifestIsRewritten() throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let pinnedManifestHash = try fixture.writeManifest()
        let originalBytes = try fixture.totalBytes()

        try Data("corrupt model".utf8).write(to: fixture.artifact)
        _ = try fixture.writeManifest()

        XCTAssertThrowsError(
            try fixture.verify(
                manifestHash: pinnedManifestHash,
                expectedArtifactCount: 1,
                expectedBytes: originalBytes
            )
        ) { error in
            XCTAssertEqual(error as? ModelResourceError, .manifestHashMismatch)
        }
    }

    func testStrictBundleRejectsDuplicateUnexpectedAndSymlinkArtifacts() throws {
        do {
            let fixture = try ModelFixture()
            defer { fixture.remove() }
            let hash = try fixture.writeManifest(duplicateArtifact: true)
            XCTAssertThrowsError(
                try fixture.verify(
                    manifestHash: hash,
                    expectedArtifactCount: 2,
                    expectedBytes: try fixture.totalBytes()
                )
            ) { error in
                XCTAssertEqual(error as? ModelResourceError, .duplicateArtifact("model.bin"))
            }
        }

        do {
            let fixture = try ModelFixture()
            defer { fixture.remove() }
            let hash = try fixture.writeManifest()
            try Data("unapproved".utf8).write(to: fixture.root.appending(path: "extra.bin"))
            XCTAssertThrowsError(
                try fixture.verify(
                    manifestHash: hash,
                    expectedArtifactCount: 1,
                    expectedBytes: try fixture.totalBytes()
                )
            ) { error in
                XCTAssertEqual(error as? ModelResourceError, .unexpectedArtifact("extra.bin"))
            }
        }

        do {
            let fixture = try ModelFixture()
            defer { fixture.remove() }
            let hash = try fixture.writeManifest()
            try FileManager.default.createSymbolicLink(
                at: fixture.root.appending(path: "alias.bin"),
                withDestinationURL: fixture.artifact
            )
            XCTAssertThrowsError(
                try fixture.verify(
                    manifestHash: hash,
                    expectedArtifactCount: 1,
                    expectedBytes: try fixture.totalBytes()
                )
            ) { error in
                XCTAssertEqual(error as? ModelResourceError, .symbolicLinkForbidden("alias.bin"))
            }
        }
    }

    func testTextPreprocessorHasFrozenCLIPTokenSequence() throws {
        let preprocessor = try MobileCLIPTextPreprocessor.bundled()
        let tokens = try preprocessor.tokens(for: "a red square")

        XCTAssertEqual(tokens.count, 77)
        XCTAssertEqual(Array(tokens.prefix(5)), [49_406, 320, 736, 3_999, 49_407])
        XCTAssertTrue(tokens.dropFirst(5).allSatisfy { $0 == 0 })
    }

    func testImagePreprocessorProducesExactSquareBGRAAndOpaqueAlpha() throws {
        var rgba = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for index in 0..<(256 * 256) {
            let offset = index * 4
            rgba[offset] = UInt8(index % 251)
            rgba[offset + 1] = UInt8((index * 3) % 251)
            rgba[offset + 2] = UInt8((index * 7) % 251)
            rgba[offset + 3] = 17
        }
        let raster = try ThumbnailRaster(
            width: 256,
            height: 256,
            rgba8: rgba,
            colorSpace: .sRGB
        )

        let prepared = try MobileCLIPImagePreprocessor().prepare(raster)

        XCTAssertEqual(prepared.bgra8.count, 256 * 256 * 4)
        for pixel in [0, 1, 15_537, 65_535] {
            let offset = pixel * 4
            XCTAssertEqual(prepared.bgra8[offset], rgba[offset + 2])
            XCTAssertEqual(prepared.bgra8[offset + 1], rgba[offset + 1])
            XCTAssertEqual(prepared.bgra8[offset + 2], rgba[offset])
            XCTAssertEqual(prepared.bgra8[offset + 3], 255)
        }
    }

    func testImagePreprocessorUsesDeterministicAspectFillCenterCrop() throws {
        var rgba = [UInt8](repeating: 0, count: 6 * 2 * 4)
        for y in 0..<2 {
            for x in 0..<6 {
                let offset = (y * 6 + x) * 4
                rgba[offset] = x < 2 ? 255 : 0
                rgba[offset + 1] = (2...3).contains(x) ? 255 : 0
                rgba[offset + 2] = x > 3 ? 255 : 0
                rgba[offset + 3] = 255
            }
        }
        let raster = try ThumbnailRaster(width: 6, height: 2, rgba8: rgba, colorSpace: .sRGB)

        let first = try MobileCLIPImagePreprocessor().prepare(raster)
        let second = try MobileCLIPImagePreprocessor().prepare(raster)
        let firstPixel = 0
        let center = (128 * 256 + 128) * 4
        let lastPixel = (256 * 256 - 1) * 4

        XCTAssertEqual(first, second)
        for offset in [firstPixel, center, lastPixel] {
            XCTAssertEqual(first.bgra8[offset], 0)
            XCTAssertEqual(first.bgra8[offset + 1], 255)
            XCTAssertEqual(first.bgra8[offset + 2], 0)
            XCTAssertEqual(first.bgra8[offset + 3], 255)
        }
    }

    func testCorruptStartupRemainsUnavailableAndNeverReturnsResults() async throws {
        let loadCount = LockedCounter()
        let service = MobileCLIPModelService {
            loadCount.increment()
            throw ModelResourceError.hashMismatch("model.bin")
        }

        let availability = await service.start()
        XCTAssertEqual(
            availability,
            .unavailable(reason: .integrityFailure, diagnosticCode: "MCLIP-INTEGRITY")
        )
        await assertUnavailable(service, expected: .integrityFailure)
        await assertUnavailable(service, expected: .integrityFailure)
        XCTAssertEqual(loadCount.value, 1)
    }

    func testInferenceFailureTransitionsReadyServiceToFailClosedUnavailable() async throws {
        let inferenceCount = LockedCounter()
        let loaded = MobileCLIPLoadedRuntime(
            descriptor: fixtureDescriptor,
            runtime: FailingRuntime(inferenceCount: inferenceCount)
        )
        let service = MobileCLIPModelService { loaded }

        let availability = await service.start()
        XCTAssertEqual(availability, .ready(fixtureDescriptor))
        do {
            _ = try await service.embed(text: "query")
            XCTFail("Expected inference failure")
        } catch {
            XCTAssertEqual(
                error as? MobileCLIPServiceError,
                .modelUnavailable(.inferenceFailure)
            )
        }
        await assertUnavailable(service, expected: .inferenceFailure)
        XCTAssertEqual(inferenceCount.value, 1)
    }

    private var fixtureDescriptor: MobileCLIPModelDescriptor {
        MobileCLIPModelDescriptor(
            verifiedResources: VerifiedModelResources(
                version: "fixture-v1",
                manifestSHA256: String(repeating: "a", count: 64),
                artifactCount: 2,
                bundledFootprintBytes: 64
            )
        )
    }

    private func assertUnavailable(
        _ service: MobileCLIPModelService,
        expected: MobileCLIPUnavailableReason
    ) async {
        do {
            _ = try await service.embed(text: "must not run")
            XCTFail("Unavailable service returned a result")
        } catch {
            XCTAssertEqual(error as? MobileCLIPServiceError, .modelUnavailable(expected))
        }
    }
}

private struct FailingRuntime: MobileCLIPEmbeddingRuntime {
    let inferenceCount: LockedCounter

    func embed(text _: String) async throws -> [Float] {
        inferenceCount.increment()
        throw CocoaError(.coderReadCorrupt)
    }

    func embed(raster _: ThumbnailRaster) async throws -> [Float] {
        inferenceCount.increment()
        throw CocoaError(.coderReadCorrupt)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class ModelFixture {
    let root: URL
    let artifact: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "mobileclip-model-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        artifact = root.appending(path: "model.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("approved model".utf8).write(to: artifact)
    }

    func writeManifest(duplicateArtifact: Bool = false) throws -> String {
        let hash = try ModelResourceIntegrity.sha256(of: artifact)
        var artifacts = [ModelResourceArtifact(relativePath: "model.bin", sha256: hash)]
        if duplicateArtifact {
            artifacts.append(ModelResourceArtifact(relativePath: "model.bin", sha256: hash))
        }
        let manifest = ModelResourceManifest(version: "fixture-v1", artifacts: artifacts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: root.appending(path: "model-manifest.json"),
            options: .atomic
        )
        return try ModelResourceIntegrity.sha256(
            of: root.appending(path: "model-manifest.json")
        )
    }

    func totalBytes() throws -> Int {
        let artifactBytes = try artifact.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let manifestBytes =
            try root.appending(path: "model-manifest.json")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return artifactBytes + manifestBytes
    }

    func verify(
        manifestHash: String,
        expectedArtifactCount: Int,
        expectedBytes: Int
    ) throws -> VerifiedModelResources {
        try ModelResourceIntegrity.verifyBundle(
            root: root,
            expectedManifestSHA256: manifestHash,
            expectedVersion: "fixture-v1",
            expectedArtifactCount: expectedArtifactCount,
            expectedBundledFootprintBytes: expectedBytes
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
