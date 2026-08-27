import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MemoryCapture
import XCTest

final class CaptureMediaIntegrationTests: XCTestCase {
    func testHardwareRequiredHEVCWriterProducesPlayableMovie() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepshelves-hevc-\(UUID().uuidString.lowercased()).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let dimensions = PixelSize(width: 320, height: 240)
        let writer = try HEVCMediaWriter(outputURL: outputURL, dimensions: dimensions)
        for second in 0 ..< 3 {
            let sampleBuffer = try makeSampleBuffer(dimensions: dimensions, second: second)
            var appended = false
            for _ in 0 ..< 100 where !appended {
                appended = try writer.append(sampleBuffer)
                if !appended {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            XCTAssertTrue(appended)
        }
        try await writer.finish()

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? UInt64 ?? 0, 0)
        let asset = AVURLAsset(url: outputURL)
        let isPlayable = try await asset.load(.isPlayable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(isPlayable)
        XCTAssertFalse(videoTracks.isEmpty)
    }

    private func makeSampleBuffer(dimensions: PixelSize, second: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
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
        for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let address = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                throw CaptureMediaTestError.missingPlane
            }
            let byteCount = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            memset(address, Int32(plane == 0 ? 128 + second : 128), byteCount)
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
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMTime(value: CMTimeValue(second), timescale: 1),
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

private enum CaptureMediaTestError: Error {
    case pixelBuffer(CVReturn)
    case missingPlane
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}
