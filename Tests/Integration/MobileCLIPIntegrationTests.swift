import CoreVideo
import MemoryEnrichment
import XCTest

final class MobileCLIPIntegrationTests: XCTestCase {
    func testBundledMobileCLIPProducesNormalizedImageAndTextEmbeddings() async throws {
        let runtime = try MobileCLIPRuntime.bundled()
        let image = try makePixelBuffer(red: 225, green: 35, blue: 45)

        let imageEmbedding = try await runtime.embed(image: MobileCLIPPixelBuffer(image))
        let textEmbedding = try await runtime.embed(text: "a red square")

        XCTAssertEqual(imageEmbedding.count, 512)
        XCTAssertEqual(textEmbedding.count, 512)
        XCTAssertEqual(norm(imageEmbedding), 1, accuracy: 1e-4)
        XCTAssertEqual(norm(textEmbedding), 1, accuracy: 1e-4)
        XCTAssertTrue(imageEmbedding.allSatisfy(\.isFinite))
        XCTAssertTrue(textEmbedding.allSatisfy(\.isFinite))
    }

    private func makePixelBuffer(red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            256,
            256,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw CocoaError(.coderInvalidValue)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            throw CocoaError(.coderInvalidValue)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< 256 {
            let row = address.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< 256 {
                row[x * 4] = blue
                row[x * 4 + 1] = green
                row[x * 4 + 2] = red
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func norm(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + $1 * $1 })
    }
}
