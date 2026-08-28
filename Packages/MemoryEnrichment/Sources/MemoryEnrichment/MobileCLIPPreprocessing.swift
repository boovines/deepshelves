import CoreVideo
import Foundation

public enum MobileCLIPPreprocessingError: Error, Equatable, Sendable {
    case unsupportedColorSpace
    case invalidPreparedImage
    case pixelBufferAllocationFailed(Int32)
    case pixelBufferAddressUnavailable
}

public struct MobileCLIPPreparedImage: Equatable, Sendable {
    public static let edgeLength = 256

    public let bgra8: [UInt8]

    public init(bgra8: [UInt8]) throws {
        guard bgra8.count == Self.edgeLength * Self.edgeLength * 4 else {
            throw MobileCLIPPreprocessingError.invalidPreparedImage
        }
        self.bgra8 = bgra8
    }

    func pixelBuffer() throws -> MobileCLIPPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.edgeLength,
            Self.edgeLength,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw MobileCLIPPreprocessingError.pixelBufferAllocationFailed(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else {
            throw MobileCLIPPreprocessingError.pixelBufferAddressUnavailable
        }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        try bgra8.withUnsafeBytes { source in
            guard let sourceAddress = source.baseAddress else {
                throw MobileCLIPPreprocessingError.invalidPreparedImage
            }
            for row in 0..<Self.edgeLength {
                destination.advanced(by: row * destinationBytesPerRow).copyMemory(
                    from: sourceAddress.advanced(by: row * Self.edgeLength * 4),
                    byteCount: Self.edgeLength * 4
                )
            }
        }
        return MobileCLIPPixelBuffer(buffer)
    }
}

public struct MobileCLIPImagePreprocessor: Sendable {
    public init() {}

    public func prepare(_ raster: ThumbnailRaster) throws -> MobileCLIPPreparedImage {
        guard raster.colorSpace == .sRGB else {
            throw MobileCLIPPreprocessingError.unsupportedColorSpace
        }

        let edge = MobileCLIPPreparedImage.edgeLength
        let cropEdge = min(raster.width, raster.height)
        let originX = Double(raster.width - cropEdge) / 2
        let originY = Double(raster.height - cropEdge) / 2
        let maximumX = originX + Double(cropEdge - 1)
        let maximumY = originY + Double(cropEdge - 1)
        let scale = Double(cropEdge) / Double(edge)
        var output = [UInt8](repeating: 0, count: edge * edge * 4)

        for outputY in 0..<edge {
            let rawSourceY = originY + (Double(outputY) + 0.5) * scale - 0.5
            let sourceY = min(max(rawSourceY, originY), maximumY)
            let y0 = clamped(Int(floor(sourceY)), upperBound: raster.height - 1)
            let y1 = min(y0 + 1, raster.height - 1)
            let yWeight = min(max(sourceY - Double(y0), 0), 1)
            for outputX in 0..<edge {
                let rawSourceX = originX + (Double(outputX) + 0.5) * scale - 0.5
                let sourceX = min(max(rawSourceX, originX), maximumX)
                let x0 = clamped(Int(floor(sourceX)), upperBound: raster.width - 1)
                let x1 = min(x0 + 1, raster.width - 1)
                let xWeight = min(max(sourceX - Double(x0), 0), 1)
                let outputOffset = (outputY * edge + outputX) * 4

                for outputChannel in 0..<3 {
                    let sourceChannel = 2 - outputChannel
                    let topLeft = sample(raster, x: x0, y: y0, channel: sourceChannel)
                    let topRight = sample(raster, x: x1, y: y0, channel: sourceChannel)
                    let bottomLeft = sample(raster, x: x0, y: y1, channel: sourceChannel)
                    let bottomRight = sample(raster, x: x1, y: y1, channel: sourceChannel)
                    let top = interpolate(topLeft, topRight, weight: xWeight)
                    let bottom = interpolate(bottomLeft, bottomRight, weight: xWeight)
                    let value = interpolate(top, bottom, weight: yWeight)
                    output[outputOffset + outputChannel] = UInt8(
                        clamping: Int(value.rounded(.toNearestOrAwayFromZero))
                    )
                }
                output[outputOffset + 3] = 255
            }
        }
        return try MobileCLIPPreparedImage(bgra8: output)
    }

    private func clamped(_ value: Int, upperBound: Int) -> Int {
        min(max(value, 0), upperBound)
    }

    private func sample(_ raster: ThumbnailRaster, x: Int, y: Int, channel: Int) -> Double {
        Double(raster.rgba8[(y * raster.width + x) * 4 + channel])
    }

    private func interpolate(_ first: Double, _ second: Double, weight: Double) -> Double {
        first + (second - first) * weight
    }
}

public struct MobileCLIPTextPreprocessor: Sendable {
    public static let contextLength = 77

    private let tokenizer: CLIPTokenizer

    public init(resourcesRoot: URL) throws {
        tokenizer = try CLIPTokenizer(resourcesRoot: resourcesRoot)
    }

    public static func bundled() throws -> MobileCLIPTextPreprocessor {
        let root = try MobileCLIPRuntime.bundledResourceRoot()
        _ = try MobileCLIPRuntime.verifyBundledResources(root: root)
        return try MobileCLIPTextPreprocessor(resourcesRoot: root)
    }

    public func tokens(for text: String) throws -> [Int32] {
        try tokenizer.encodeFull(text: text).map { Int32($0) }
    }
}
