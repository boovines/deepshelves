import CoreVideo
import CryptoKit
import Foundation
import MemoryCapture
import MemoryContracts
import XCTest

final class CaptureMediaIntegrationTests: XCTestCase {
    func testHEICWriterPublishesExactScopedFrameAssetsWithoutVideoEncoding() throws {
        let fixture = try MediaWriterFixture(name: "heic-scoped")
        defer { fixture.remove() }
        let chunkID = UUID()
        let epochID = UUID()
        let scope = MediaChunkScope(
            epochID: epochID,
            targetWindowID: 42,
            dimensions: MemoryCapture.PixelSize(width: 320, height: 180),
            startedNanoseconds: 0
        )
        let encoder = SafeFakeHEICEncoder(payloads: [
            Data("frame-one".utf8),
            Data("frame-two".utf8),
            Data("frame-three".utf8),
        ])
        let writer = try HEICKeyframeWriter(
            outputDirectoryURL: fixture.outputURL,
            chunkID: chunkID,
            scope: scope,
            encoder: encoder
        )
        let source = try makePixelBuffer(width: 640, height: 360)
        let frameIDs = [UUID(), UUID(), UUID()]
        for (frameID, time) in zip(frameIDs, [10_000, 10_400, 11_750]) {
            _ = try writer.append(
                source,
                frameID: frameID,
                captureEpochID: epochID,
                targetWindowID: 42,
                sourcePresentationTimeMilliseconds: Int64(time)
            )
        }
        let finalized = try XCTUnwrap(writer.finish())

        XCTAssertEqual(finalized.chunkID, chunkID)
        XCTAssertEqual(finalized.scope, scope)
        XCTAssertEqual(finalized.frameCount, 3)
        XCTAssertEqual(
            finalized.locators.map(\.presentationTimeMilliseconds),
            [0, 400, 1_750]
        )
        XCTAssertEqual(finalized.locators.map(\.frameID), frameIDs)
        XCTAssertEqual(encoder.destinations.count, 3)
        XCTAssertTrue(encoder.destinations.allSatisfy { $0 == scope.dimensions })

        let manifestURL = fixture.outputURL.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        XCTAssertEqual(finalized.sha256, Data(SHA256.hash(data: manifestData)))
        for entry in finalized.manifest.frames {
            let data = try Data(
                contentsOf: fixture.outputURL.appendingPathComponent(entry.relativePath))
            XCTAssertEqual(Int64(data.count), entry.byteCount)
            XCTAssertEqual(Data(SHA256.hash(data: data)), entry.sha256)
        }
    }

    func testScopeRejectionOccursBeforeTheHEICEncoderBoundary() throws {
        let fixture = try MediaWriterFixture(name: "heic-scope")
        defer { fixture.remove() }
        let epochID = UUID()
        let encoder = SafeFakeHEICEncoder(payloads: [Data("must-not-encode".utf8)])
        let writer = try HEICKeyframeWriter(
            outputDirectoryURL: fixture.outputURL,
            scope: MediaChunkScope(
                epochID: epochID,
                targetWindowID: 9,
                dimensions: MemoryCapture.PixelSize(width: 320, height: 180),
                startedNanoseconds: 0
            ),
            encoder: encoder
        )
        let source = try makePixelBuffer(width: 320, height: 180)

        XCTAssertThrowsError(
            try writer.append(
                source,
                frameID: UUID(),
                captureEpochID: UUID(),
                targetWindowID: 9,
                sourcePresentationTimeMilliseconds: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? HEICKeyframeWriterError, .scopeMismatch)
        }
        XCTAssertEqual(encoder.destinations.count, 0)
        writer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectoryURL.path))
    }

    func testEmptyHEICWriterPublishesNothing() throws {
        let fixture = try MediaWriterFixture(name: "heic-empty")
        defer { fixture.remove() }
        let writer = try HEICKeyframeWriter(
            outputDirectoryURL: fixture.outputURL,
            scope: MediaChunkScope(
                epochID: UUID(),
                targetWindowID: 1,
                dimensions: MemoryCapture.PixelSize(width: 320, height: 180),
                startedNanoseconds: 0
            ),
            encoder: SafeFakeHEICEncoder(payloads: [])
        )

        XCTAssertNil(try writer.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectoryURL.path))
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CaptureMediaTestError.pixelBuffer(status)
        }
        return pixelBuffer
    }
}

private final class SafeFakeHEICEncoder: HEICFrameEncoding, @unchecked Sendable {
    private var payloads: [Data]
    private(set) var destinations: [MemoryCapture.PixelSize] = []

    init(payloads: [Data]) {
        self.payloads = payloads
    }

    func encode(
        _ source: CVPixelBuffer,
        destinationDimensions: MemoryCapture.PixelSize
    ) throws -> Data {
        destinations.append(destinationDimensions)
        guard !payloads.isEmpty else {
            throw CaptureMediaTestError.missingPayload
        }
        return payloads.removeFirst()
    }
}

private final class MediaWriterFixture {
    let root: URL
    let outputURL: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm025-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        outputURL = root.appendingPathComponent("chunk", isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum CaptureMediaTestError: Error {
    case pixelBuffer(CVReturn)
    case missingPayload
}
