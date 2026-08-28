import CryptoKit
import Foundation
import MemoryContracts
import MemoryEnrichment
import MemoryStore
import XCTest

final class ThumbnailPipelineTests: XCTestCase {
    func testAspectFitLongEdgeIsExactly480WithoutUpscaling() throws {
        let source = try ThumbnailSourceImage(
            raster: solidRaster(width: 960, height: 540),
            orientation: .up
        )
        let thumbnail = try ThumbnailRasterizer().render(source)
        XCTAssertEqual(thumbnail.width, 480)
        XCTAssertEqual(thumbnail.height, 270)
        XCTAssertEqual(thumbnail.colorSpace, .sRGB)

        let small = try ThumbnailSourceImage(
            raster: solidRaster(width: 120, height: 80),
            orientation: .up
        )
        XCTAssertEqual(try ThumbnailRasterizer().render(small).size, .init(width: 120, height: 80))
    }

    func testAllEightOrientationsProducePinnedPixelOrder() throws {
        let raster = try ThumbnailRaster(
            width: 3,
            height: 2,
            rgba8: pixels([1, 2, 3, 4, 5, 6]),
            colorSpace: .sRGB
        )
        let expected: [ThumbnailOrientation: (ThumbnailPixelSize, [UInt8])] = [
            .up: (.init(width: 3, height: 2), [1, 2, 3, 4, 5, 6]),
            .upMirrored: (.init(width: 3, height: 2), [3, 2, 1, 6, 5, 4]),
            .down: (.init(width: 3, height: 2), [6, 5, 4, 3, 2, 1]),
            .downMirrored: (.init(width: 3, height: 2), [4, 5, 6, 1, 2, 3]),
            .leftMirrored: (.init(width: 2, height: 3), [1, 4, 2, 5, 3, 6]),
            .right: (.init(width: 2, height: 3), [4, 1, 5, 2, 6, 3]),
            .rightMirrored: (.init(width: 2, height: 3), [6, 3, 5, 2, 4, 1]),
            .left: (.init(width: 2, height: 3), [3, 6, 2, 5, 1, 4]),
        ]

        for orientation in ThumbnailOrientation.allCases {
            let output = try ThumbnailRasterizer().render(
                ThumbnailSourceImage(raster: raster, orientation: orientation)
            )
            XCTAssertEqual(output.size, expected[orientation]?.0, "\(orientation)")
            XCTAssertEqual(redChannel(output.rgba8), expected[orientation]?.1, "\(orientation)")
        }
    }

    func testDisplayP3IsConvertedToTaggedSRGBAndAlphaIsPreserved() throws {
        let raster = try ThumbnailRaster(
            width: 1,
            height: 1,
            rgba8: [255, 0, 0, 127],
            colorSpace: .displayP3
        )
        let output = try ThumbnailRasterizer().render(
            ThumbnailSourceImage(raster: raster, orientation: .up)
        )
        XCTAssertEqual(output.colorSpace, .sRGB)
        XCTAssertGreaterThanOrEqual(output.rgba8[0], 250)
        XCTAssertLessThanOrEqual(output.rgba8[1], 2)
        XCTAssertLessThanOrEqual(output.rgba8[2], 2)
        XCTAssertEqual(output.rgba8[3], 127)
    }

    func testAtomicHashVerifiedPublicationReuseAndMissingFileRebuild() throws {
        let fixture = try FixtureThumbnailArchive()
        defer { fixture.remove() }
        let decoder = FixtureThumbnailDecoder(
            image: try ThumbnailSourceImage(
                raster: solidRaster(width: 800, height: 400), orientation: .right)
        )
        let generator = ThumbnailGenerator(
            fileStore: fixture.store,
            decoder: decoder,
            encoder: FixtureThumbnailEncoder(),
            producer: producer,
            now: { Date(timeIntervalSince1970: 1_788_000_000) },
            artifactIDProvider: { frameID in frameID }
        )
        var committed: [EnrichmentArtifact] = []

        let generated = try generator.ensure(
            fixture.request,
            expectedThumbnailHash: nil,
            databaseCommit: { committed.append($0) }
        )
        XCTAssertEqual(generated.disposition, .generated)
        XCTAssertEqual(generated.pixelSize, .init(width: 240, height: 480))
        XCTAssertEqual(generated.contentHash.count, 32)
        XCTAssertEqual(generated.artifact.kind, .thumbnail)
        XCTAssertEqual(generated.artifact.contentHash, generated.contentHash)
        XCTAssertEqual(committed, [generated.artifact])
        XCTAssertEqual(decoder.callCount, 1)
        let outputURL = fixture.store.url(for: generated.relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.store.partialURL(for: generated.relativePath).path))

        let reused = try generator.ensure(
            fixture.request,
            expectedThumbnailHash: generated.contentHash,
            databaseCommit: { _ in XCTFail("Reuse must not recommit") }
        )
        XCTAssertEqual(reused.disposition, .reused)
        XCTAssertEqual(decoder.callCount, 1)

        try FileManager.default.removeItem(at: outputURL)
        let rebuilt = try generator.ensure(
            fixture.request,
            expectedThumbnailHash: generated.contentHash,
            databaseCommit: { committed.append($0) }
        )
        XCTAssertEqual(rebuilt.disposition, .rebuiltMissing)
        XCTAssertEqual(rebuilt.contentHash, generated.contentHash)
        XCTAssertEqual(decoder.callCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        var databaseDeleted = false
        try generator.delete(
            relativePath: rebuilt.relativePath,
            expectedHash: rebuilt.contentHash,
            databaseDelete: { databaseDeleted = true }
        )
        XCTAssertTrue(databaseDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.store.partialURL(for: rebuilt.relativePath).path
            )
        )
    }

    func testSourceHashMismatchAndQuarantinedRuntimeAdaptersFailBeforePublication() throws {
        let fixture = try FixtureThumbnailArchive()
        defer { fixture.remove() }
        var request = fixture.request
        request = try ThumbnailGenerationRequest(
            frameID: request.frameID,
            capturedAt: request.capturedAt,
            sourcePath: request.sourcePath,
            expectedSourceHash: Data(repeating: 0xDD, count: 32)
        )
        let generator = ThumbnailGenerator(
            fileStore: fixture.store,
            decoder: QuarantinedThumbnailHEICDecoder(),
            encoder: QuarantinedThumbnailHEICEncoder(),
            producer: producer
        )

        XCTAssertThrowsError(try generator.ensure(request, expectedThumbnailHash: nil)) { error in
            XCTAssertEqual(error as? ThumbnailPipelineError, .sourceIntegrityMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.expectedThumbnailURL.path))

        XCTAssertThrowsError(
            try QuarantinedThumbnailHEICDecoder().decode(Data([1, 2, 3]))
        ) { error in
            XCTAssertEqual(error as? ThumbnailPipelineError, .runtimeCodecQuarantined)
        }
        XCTAssertThrowsError(
            try QuarantinedThumbnailHEICEncoder().encode(solidRaster(width: 1, height: 1))
        ) {
            error in
            XCTAssertEqual(error as? ThumbnailPipelineError, .runtimeCodecQuarantined)
        }
    }
}

private let producer = try! ProducerVersion(
    name: "thumbnail-pipeline",
    semanticVersion: "1.0.0",
    modelHash: Data(SHA256.hash(data: Data("thumbnail-pipeline-v1".utf8)))
)

private final class FixtureThumbnailDecoder: ThumbnailHEICDecoding, @unchecked Sendable {
    let image: ThumbnailSourceImage
    private(set) var callCount = 0
    init(image: ThumbnailSourceImage) { self.image = image }
    func decode(_ data: Data) throws -> ThumbnailSourceImage {
        callCount += 1
        return image
    }
}

private struct FixtureThumbnailEncoder: ThumbnailHEICEncoding {
    func encode(_ raster: ThumbnailRaster) throws -> Data {
        Data("FAKE-HEIC-\(raster.width)x\(raster.height)-srgb:".utf8) + raster.rgba8
    }
}

private final class FixtureThumbnailArchive {
    let support: URL
    let store: ArchiveFileStore
    let request: ThumbnailGenerationRequest
    let expectedThumbnailURL: URL

    init() throws {
        support = FileManager.default.temporaryDirectory.appending(
            path: "LM033-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = try ArchivePathProvider.prepare(applicationSupportDirectory: support)
        store = ArchiveFileStore(paths: paths)
        let frameID = UUID(uuidString: "33000000-0000-0000-0000-000000000001")!
        let sourcePath = try ArchiveRelativePath(
            "media/2026/08/28/chunk/frames/\(frameID.uuidString.lowercased()).heic")
        let sourceBytes = Data("PINNED-SOURCE-HEIC-BYTES".utf8)
        _ = try store.write(sourceBytes, to: sourcePath)
        request = try ThumbnailGenerationRequest(
            frameID: frameID,
            capturedAt: Date(timeIntervalSince1970: 1_777_777_700),
            sourcePath: sourcePath,
            expectedSourceHash: Data(SHA256.hash(data: sourceBytes))
        )
        expectedThumbnailURL = paths.root.appending(
            path: "thumbnails/2026/05/03/\(frameID.uuidString.lowercased()).heic")
    }

    func remove() { try? FileManager.default.removeItem(at: support) }
}

private func solidRaster(width: Int, height: Int) throws -> ThumbnailRaster {
    try ThumbnailRaster(
        width: width,
        height: height,
        rgba8: Array(repeating: [UInt8(44), 88, 132, 255], count: width * height).flatMap { $0 },
        colorSpace: .sRGB
    )
}

private func pixels(_ red: [UInt8]) -> [UInt8] {
    red.flatMap { [$0, 0, 0, 255] }
}

private func redChannel(_ rgba: [UInt8]) -> [UInt8] {
    stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] }
}
