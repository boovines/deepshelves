import CoreGraphics
import CoreText
import CoreVideo
import MemoryEnrichment
import XCTest

final class MobileCLIPIntegrationTests: XCTestCase {
    func testBundledMobileCLIPProducesNormalizedImageAndTextEmbeddings() async throws {
        let service = MobileCLIPModelService.bundled()
        let availability = await service.start()
        guard case .ready(let descriptor) = availability else {
            return XCTFail("Bundled MobileCLIP service did not become ready")
        }
        let raster = try solidRaster(red: 225, green: 35, blue: 45)

        let imageEmbedding = try await service.embed(raster: raster)
        let textEmbedding = try await service.embed(text: "a red square")

        XCTAssertEqual(descriptor.version, MobileCLIPRuntime.version)
        XCTAssertEqual(descriptor.manifestSHA256, MobileCLIPRuntime.manifestSHA256)
        XCTAssertEqual(imageEmbedding.count, 512)
        XCTAssertEqual(textEmbedding.count, 512)
        XCTAssertEqual(norm(imageEmbedding), 1, accuracy: 1e-4)
        XCTAssertEqual(norm(textEmbedding), 1, accuracy: 1e-4)
        XCTAssertTrue(imageEmbedding.allSatisfy(\.isFinite))
        XCTAssertTrue(textEmbedding.allSatisfy(\.isFinite))
    }

    private func solidRaster(red: UInt8, green: UInt8, blue: UInt8) throws -> ThumbnailRaster {
        var rgba = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for pixel in 0..<(256 * 256) {
            let offset = pixel * 4
            rgba[offset] = red
            rgba[offset + 1] = green
            rgba[offset + 2] = blue
            rgba[offset + 3] = 255
        }
        return try ThumbnailRaster(width: 256, height: 256, rgba8: rgba, colorSpace: .sRGB)
    }

    func testBundledRuntimeReproducesCanonicalS3ImageAndTextParityVectors() async throws {
        let runtime = try MobileCLIPRuntime.bundled()
        let raster = try makeS3ParityRaster()
        let imageEmbedding = try await runtime.embed(raster: raster)
        let textEmbedding = try await runtime.embed(text: "a photo of an apple")
        let referenceRoot = repositoryRoot.appending(
            path: "Benchmarks/Results/S3S4/20260827T193136Z/raw",
            directoryHint: .isDirectory
        )
        let imageReference = try readFloatVector(
            referenceRoot.appending(path: "packaged-parity-image.f32")
        )
        let textReference = try readFloatVector(
            referenceRoot.appending(path: "packaged-parity-text.f32")
        )

        XCTAssertEqual(imageReference.count, 512)
        XCTAssertEqual(textReference.count, 512)
        XCTAssertEqual(cosine(imageEmbedding, imageReference), 1, accuracy: 1e-6)
        XCTAssertEqual(cosine(textEmbedding, textReference), 1, accuracy: 1e-6)
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
        for y in 0..<256 {
            let row = address.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<256 {
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

    private func cosine(_ left: [Float], _ right: [Float]) -> Float {
        zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readFloatVector(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw CocoaError(.coderReadCorrupt)
        }
        var values = [Float](
            repeating: 0,
            count: data.count / MemoryLayout<Float>.size
        )
        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return values
    }

    private func makeS3ParityRaster() throws -> ThumbnailRaster {
        let buffer = try makePixelBuffer(red: 0, green: 0, blue: 0)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
            let context = CGContext(
                data: base,
                width: 256,
                height: 256,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            throw CocoaError(.coderInvalidValue)
        }

        context.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(red: 0.88, green: 0.12, blue: 0.14, alpha: 1))
        context.fillEllipse(in: CGRect(x: 22, y: 66, width: 212, height: 156))
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fill(CGRect(x: 12, y: 14, width: 232, height: 55))
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 32, nil),
            kCTForegroundColorAttributeName: CGColor(gray: 0.05, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, "APPLE" as CFString, attributes as CFDictionary)
        )
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: max(10, (256 - textWidth) / 2), y: 27)
        CTLineDraw(line, context)

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var rgba = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for y in 0..<256 {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<256 {
                let source = x * 4
                let destination = (y * 256 + x) * 4
                rgba[destination] = row[source + 2]
                rgba[destination + 1] = row[source + 1]
                rgba[destination + 2] = row[source]
                rgba[destination + 3] = row[source + 3]
            }
        }
        return try ThumbnailRaster(width: 256, height: 256, rgba8: rgba, colorSpace: .sRGB)
    }
}
