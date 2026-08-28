import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import MemoryCapture
import XCTest

final class CaptureMediaIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        throw XCTSkip(
            "LM-025 hardware HEVC quarantine: two repeatable dart-ave AppleT8110DART "
                + "kernel panics on macOS 26.5 at 2026-08-28 14:43 and 14:49. "
                + "Do not remove this skip until the hardware/OS gate is explicitly re-authorized."
        )
    }

    func testHardwareRequiredVFRWriterDownscalesAndFinalizesScopedChunk() async throws {
        let fixture = try MediaWriterFixture(name: "vfr")
        defer { fixture.remove() }
        let chunkID = UUID()
        let epochID = UUID()
        let scope = MediaChunkScope(
            epochID: epochID,
            targetWindowID: 42,
            dimensions: PixelSize(width: 320, height: 180),
            startedNanoseconds: 0
        )
        let writer = try HEVCMediaWriter(
            outputURL: fixture.outputURL,
            chunkID: chunkID,
            scope: scope
        )
        let sourcePTS = [10.0, 10.4, 11.75]
        let frameIDs = sourcePTS.map { _ in UUID() }
        for (index, seconds) in sourcePTS.enumerated() {
            let sampleBuffer = try makeSampleBuffer(
                dimensions: PixelSize(width: 640, height: 360),
                seconds: seconds,
                luma: UInt8(96 + index * 32)
            )
            var appended = false
            for _ in 0..<100 where !appended {
                let locator = try writer.append(
                    sampleBuffer,
                    frameID: frameIDs[index],
                    captureEpochID: epochID,
                    targetWindowID: 42
                )
                appended = locator != nil
                if let locator {
                    XCTAssertEqual(locator.chunkID, chunkID)
                    XCTAssertEqual(locator.frameID, frameIDs[index])
                } else {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            XCTAssertTrue(appended)
        }
        let result = try await writer.finish()
        let finalized = try XCTUnwrap(result)

        XCTAssertEqual(finalized.chunkID, chunkID)
        XCTAssertEqual(finalized.scope, scope)
        XCTAssertEqual(finalized.frameCount, 3)
        XCTAssertEqual(finalized.presentationTimeMilliseconds, [0, 400, 1_750])
        XCTAssertEqual(finalized.locators.map(\.frameID), frameIDs)
        XCTAssertEqual(finalized.durationMilliseconds, 1_750)
        XCTAssertEqual(finalized.codecFourCC, "hvc1")
        XCTAssertTrue(finalized.hardwareAccelerationRequired)

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? UInt64 ?? 0, 0)
        XCTAssertEqual(Int64(attributes[.size] as? UInt64 ?? 0), finalized.byteCount)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let bytes = try Data(contentsOf: fixture.outputURL)
        XCTAssertEqual(finalized.sha256Hex, SHA256.hash(data: bytes).hexString)

        let asset = AVURLAsset(url: fixture.outputURL)
        let isPlayable = try await asset.load(.isPlayable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(isPlayable)
        let track = try XCTUnwrap(videoTracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(Int(naturalSize.width), 320)
        XCTAssertEqual(Int(naturalSize.height), 180)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        for milliseconds in finalized.presentationTimeMilliseconds {
            let time = CMTime(value: milliseconds, timescale: 1_000)
            _ = try await generator.image(at: time).image
        }
    }

    func testWriterRejectsScopeDimensionTimestampAndDurationViolations() async throws {
        let fixture = try MediaWriterFixture(name: "violations")
        defer { fixture.remove() }
        let epochID = UUID()
        let scope = MediaChunkScope(
            epochID: epochID,
            targetWindowID: 9,
            dimensions: PixelSize(width: 320, height: 180),
            startedNanoseconds: 0
        )
        let writer = try HEVCMediaWriter(outputURL: fixture.outputURL, scope: scope)
        let first = try makeSampleBuffer(
            dimensions: PixelSize(width: 320, height: 180),
            seconds: 5,
            luma: 64
        )
        _ = try writer.append(
            first,
            frameID: UUID(),
            captureEpochID: epochID,
            targetWindowID: 9
        )

        XCTAssertThrowsError(
            try writer.append(
                first,
                frameID: UUID(),
                captureEpochID: UUID(),
                targetWindowID: 9
            )
        ) { error in
            XCTAssertEqual(error as? HEVCMediaWriterError, .scopeMismatch)
        }
        XCTAssertThrowsError(
            try writer.append(
                first,
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 10
            )
        ) { error in
            XCTAssertEqual(error as? HEVCMediaWriterError, .scopeMismatch)
        }
        XCTAssertThrowsError(
            try writer.append(
                first,
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 9
            )
        ) { error in
            XCTAssertEqual(error as? HEVCMediaWriterError, .nonIncreasingPresentationTime)
        }

        let tooLate = try makeSampleBuffer(
            dimensions: PixelSize(width: 320, height: 180),
            seconds: 35.001,
            luma: 192
        )
        XCTAssertThrowsError(
            try writer.append(
                tooLate,
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 9
            )
        ) { error in
            XCTAssertEqual(error as? HEVCMediaWriterError, .maximumDurationExceeded)
        }
        let result = try await writer.finish()
        let finalized = try XCTUnwrap(result)
        XCTAssertEqual(finalized.frameCount, 1)
        XCTAssertLessThanOrEqual(finalized.durationMilliseconds, 30_000)
    }

    func testEmptyWriterFinalizationRemovesPartialAndPublishesNothing() async throws {
        let fixture = try MediaWriterFixture(name: "empty")
        defer { fixture.remove() }
        let writer = try HEVCMediaWriter(
            outputURL: fixture.outputURL,
            scope: MediaChunkScope(
                epochID: UUID(),
                targetWindowID: 1,
                dimensions: PixelSize(width: 320, height: 180),
                startedNanoseconds: 0
            )
        )

        let result = try await writer.finish()
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.partialURL.path))
    }

    private func makeSampleBuffer(
        dimensions: PixelSize,
        seconds: Double,
        luma: UInt8
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            dimensions.width,
            dimensions.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw CaptureMediaTestError.pixelBuffer(pixelStatus)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let address = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                throw CaptureMediaTestError.missingPlane
            }
            let byteCount =
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            memset(address, Int32(plane == 0 ? luma : 128), byteCount)
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw CaptureMediaTestError.formatDescription(formatStatus)
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CaptureMediaTestError.sampleBuffer(sampleStatus)
        }
        return sampleBuffer
    }
}

private struct MediaWriterFixture {
    let root: URL
    let outputURL: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm025-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        outputURL = root.appendingPathComponent("chunk.mov")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private enum CaptureMediaTestError: Error {
    case pixelBuffer(CVReturn)
    case missingPlane
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}
