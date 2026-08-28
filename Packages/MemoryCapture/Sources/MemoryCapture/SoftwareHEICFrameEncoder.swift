import CoreVideo
import Foundation
import MemorySoftwareHEIC

public struct SoftwareHEICFrameEncoder: HEICFrameEncoding {
    public static let productionQuality = 82

    private let codec: SoftwareHEICCodec
    private let quality: Int

    public init(
        codec: SoftwareHEICCodec,
        quality: Int = SoftwareHEICFrameEncoder.productionQuality
    ) {
        self.codec = codec
        self.quality = min(max(quality, 0), 100)
    }

    public init(quality: Int = SoftwareHEICFrameEncoder.productionQuality) throws {
        self.init(codec: try SoftwareHEICCodec(), quality: quality)
    }

    public func encode(
        _ source: CVPixelBuffer,
        destinationDimensions: PixelSize
    ) throws -> Data {
        let raster = try rgbaRaster(
            from: source,
            destinationDimensions: destinationDimensions
        )
        let data = try codec.encode(raster, quality: quality)
        guard !data.isEmpty else {
            throw HEICFrameEncoderError.emptyPayload
        }
        return data
    }

    private func rgbaRaster(
        from source: CVPixelBuffer,
        destinationDimensions: PixelSize
    ) throws -> SoftwareHEICRaster {
        guard
            CVPixelBufferGetPixelFormatType(source)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            CVPixelBufferGetPlaneCount(source) == 2
        else {
            throw HEICFrameEncoderError.unsupportedPixelFormat
        }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw HEICFrameEncoderError.pixelBufferUnavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(source, 0),
            let uvBase = CVPixelBufferGetBaseAddressOfPlane(source, 1)
        else {
            throw HEICFrameEncoderError.pixelBufferUnavailable
        }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let yBytes = yBase.assumingMemoryBound(to: UInt8.self)
        let uvBytes = uvBase.assumingMemoryBound(to: UInt8.self)
        let width = destinationDimensions.width
        let height = destinationDimensions.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        for destinationY in 0..<height {
            let sourceY = min(sourceHeight - 1, destinationY * sourceHeight / height)
            for destinationX in 0..<width {
                let sourceX = min(sourceWidth - 1, destinationX * sourceWidth / width)
                let yValue = Double(yBytes[sourceY * yStride + sourceX])
                let uvOffset = (sourceY / 2) * uvStride + (sourceX / 2) * 2
                let cb = Double(uvBytes[uvOffset]) - 128
                let cr = Double(uvBytes[uvOffset + 1]) - 128
                let luma = (yValue - 16) * (255 / 219)
                let offset = (destinationY * width + destinationX) * 4
                rgba[offset] = clamp(luma + 1.5748 * cr)
                rgba[offset + 1] = clamp(luma - 0.1873 * cb - 0.4681 * cr)
                rgba[offset + 2] = clamp(luma + 1.8556 * cb)
            }
        }
        return try SoftwareHEICRaster(width: width, height: height, rgba8: rgba)
    }

    private func clamp(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, value)).rounded())
    }
}
