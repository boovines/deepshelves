import CryptoKit
import Foundation
import MemoryContracts
import MemoryStore

public enum ThumbnailPipelineError: Error, Equatable, Sendable {
    case invalidRaster
    case unsupportedColorSpace
    case invalidSourcePath
    case sourceIntegrityMismatch
    case thumbnailIntegrityMismatch
    case runtimeCodecQuarantined
    case emptyEncodedThumbnail
    case sourceFileUnavailable
}

public enum ThumbnailColorSpace: String, Codable, CaseIterable, Equatable, Sendable {
    case sRGB
    case displayP3
    case linearSRGB
    case unknown
}

public enum ThumbnailOrientation: String, Codable, CaseIterable, Equatable, Sendable {
    case up
    case upMirrored
    case down
    case downMirrored
    case leftMirrored
    case right
    case rightMirrored
    case left
}

public struct ThumbnailPixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct ThumbnailRaster: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba8: [UInt8]
    public let colorSpace: ThumbnailColorSpace

    public var size: ThumbnailPixelSize {
        ThumbnailPixelSize(width: width, height: height)
    }

    public init(
        width: Int,
        height: Int,
        rgba8: [UInt8],
        colorSpace: ThumbnailColorSpace
    ) throws {
        guard width > 0, height > 0,
            width <= 1_920, height <= 1_920,
            rgba8.count == width * height * 4
        else {
            throw ThumbnailPipelineError.invalidRaster
        }
        self.width = width
        self.height = height
        self.rgba8 = rgba8
        self.colorSpace = colorSpace
    }
}

public struct ThumbnailSourceImage: Equatable, Sendable {
    public let raster: ThumbnailRaster
    public let orientation: ThumbnailOrientation

    public init(raster: ThumbnailRaster, orientation: ThumbnailOrientation) throws {
        guard raster.colorSpace != .unknown else {
            throw ThumbnailPipelineError.unsupportedColorSpace
        }
        self.raster = raster
        self.orientation = orientation
    }
}

public struct ThumbnailRasterizer: Sendable {
    public static let maximumLongEdge = 480

    public init() {}

    public func render(_ source: ThumbnailSourceImage) throws -> ThumbnailRaster {
        let oriented = try orient(source.raster, source.orientation)
        let converted = try convertToSRGB(oriented)
        guard max(converted.width, converted.height) > Self.maximumLongEdge else {
            return converted
        }
        let scale = Double(Self.maximumLongEdge) / Double(max(converted.width, converted.height))
        let width = max(1, Int((Double(converted.width) * scale).rounded()))
        let height = max(1, Int((Double(converted.height) * scale).rounded()))
        return try resize(converted, width: width, height: height)
    }

    private func orient(
        _ raster: ThumbnailRaster,
        _ orientation: ThumbnailOrientation
    ) throws -> ThumbnailRaster {
        let swapsAxes: Bool
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left: swapsAxes = true
        default: swapsAxes = false
        }
        let outputWidth = swapsAxes ? raster.height : raster.width
        let outputHeight = swapsAxes ? raster.width : raster.height
        var output = [UInt8](repeating: 0, count: raster.rgba8.count)

        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let sourcePoint = sourceCoordinate(
                    outputX: x,
                    outputY: y,
                    sourceWidth: raster.width,
                    sourceHeight: raster.height,
                    orientation: orientation
                )
                let sourceOffset = (sourcePoint.y * raster.width + sourcePoint.x) * 4
                let outputOffset = (y * outputWidth + x) * 4
                output[outputOffset..<(outputOffset + 4)] =
                    raster.rgba8[sourceOffset..<(sourceOffset + 4)]
            }
        }
        return try ThumbnailRaster(
            width: outputWidth,
            height: outputHeight,
            rgba8: output,
            colorSpace: raster.colorSpace
        )
    }

    private func sourceCoordinate(
        outputX x: Int,
        outputY y: Int,
        sourceWidth width: Int,
        sourceHeight height: Int,
        orientation: ThumbnailOrientation
    ) -> (x: Int, y: Int) {
        switch orientation {
        case .up: (x, y)
        case .upMirrored: (width - 1 - x, y)
        case .down: (width - 1 - x, height - 1 - y)
        case .downMirrored: (x, height - 1 - y)
        case .leftMirrored: (y, x)
        case .right: (y, height - 1 - x)
        case .rightMirrored: (width - 1 - y, height - 1 - x)
        case .left: (width - 1 - y, x)
        }
    }

    private func convertToSRGB(_ raster: ThumbnailRaster) throws -> ThumbnailRaster {
        guard raster.colorSpace != .unknown else {
            throw ThumbnailPipelineError.unsupportedColorSpace
        }
        guard raster.colorSpace != .sRGB else { return raster }
        var output = raster.rgba8
        for offset in stride(from: 0, to: output.count, by: 4) {
            let encoded = (0..<3).map { Double(raster.rgba8[offset + $0]) / 255 }
            let linear: [Double]
            switch raster.colorSpace {
            case .displayP3:
                let p3 = encoded.map(decodeTransfer)
                let x =
                    0.486_570_948_648_216_2 * p3[0]
                    + 0.265_667_693_169_093_06 * p3[1]
                    + 0.198_217_285_234_362_5 * p3[2]
                let y =
                    0.228_974_564_069_748_8 * p3[0]
                    + 0.691_738_521_836_506_4 * p3[1]
                    + 0.079_286_914_093_745 * p3[2]
                let z =
                    0.045_113_381_858_902_64 * p3[1]
                    + 1.043_944_368_900_976 * p3[2]
                linear = [
                    3.240_969_941_904_522_6 * x - 1.537_383_177_570_094 * y
                        - 0.498_610_760_293_003_4 * z,
                    -0.969_243_636_280_879_6 * x + 1.875_967_501_507_720_2 * y
                        + 0.041_555_057_407_175_59 * z,
                    0.055_630_079_696_993_66 * x - 0.203_976_958_888_976_52 * y
                        + 1.056_971_514_242_878_6 * z,
                ]
            case .linearSRGB:
                linear = encoded
            case .sRGB:
                linear = encoded.map(decodeTransfer)
            case .unknown:
                throw ThumbnailPipelineError.unsupportedColorSpace
            }
            for channel in 0..<3 {
                let value = encodeTransfer(min(1, max(0, linear[channel])))
                output[offset + channel] = UInt8((value * 255).rounded())
            }
        }
        return try ThumbnailRaster(
            width: raster.width,
            height: raster.height,
            rgba8: output,
            colorSpace: .sRGB
        )
    }

    private func decodeTransfer(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func encodeTransfer(_ value: Double) -> Double {
        value <= 0.003_130_8 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private func resize(_ source: ThumbnailRaster, width: Int, height: Int) throws
        -> ThumbnailRaster
    {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let scaleX = Double(source.width) / Double(width)
        let scaleY = Double(source.height) / Double(height)
        for y in 0..<height {
            let sourceY = min(Double(source.height - 1), (Double(y) + 0.5) * scaleY - 0.5)
            let y0 = max(0, Int(floor(sourceY)))
            let y1 = min(source.height - 1, y0 + 1)
            let yFraction = max(0, sourceY - Double(y0))
            for x in 0..<width {
                let sourceX = min(Double(source.width - 1), (Double(x) + 0.5) * scaleX - 0.5)
                let x0 = max(0, Int(floor(sourceX)))
                let x1 = min(source.width - 1, x0 + 1)
                let xFraction = max(0, sourceX - Double(x0))
                for channel in 0..<4 {
                    let top =
                        sample(source, x: x0, y: y0, channel: channel)
                        * (1 - xFraction)
                        + sample(source, x: x1, y: y0, channel: channel) * xFraction
                    let bottom =
                        sample(source, x: x0, y: y1, channel: channel)
                        * (1 - xFraction)
                        + sample(source, x: x1, y: y1, channel: channel) * xFraction
                    output[(y * width + x) * 4 + channel] = UInt8(
                        (top * (1 - yFraction) + bottom * yFraction).rounded()
                    )
                }
            }
        }
        return try ThumbnailRaster(
            width: width,
            height: height,
            rgba8: output,
            colorSpace: .sRGB
        )
    }

    private func sample(_ raster: ThumbnailRaster, x: Int, y: Int, channel: Int) -> Double {
        Double(raster.rgba8[(y * raster.width + x) * 4 + channel])
    }
}

public protocol ThumbnailHEICDecoding: Sendable {
    func decode(_ data: Data) throws -> ThumbnailSourceImage
}

public protocol ThumbnailHEICEncoding: Sendable {
    func encode(_ raster: ThumbnailRaster) throws -> Data
}

public struct QuarantinedThumbnailHEICDecoder: ThumbnailHEICDecoding {
    public init() {}
    public func decode(_ data: Data) throws -> ThumbnailSourceImage {
        throw ThumbnailPipelineError.runtimeCodecQuarantined
    }
}

public struct QuarantinedThumbnailHEICEncoder: ThumbnailHEICEncoding {
    public init() {}
    public func encode(_ raster: ThumbnailRaster) throws -> Data {
        throw ThumbnailPipelineError.runtimeCodecQuarantined
    }
}

public struct ThumbnailGenerationRequest: Equatable, Sendable {
    public let frameID: UUID
    public let capturedAt: Date
    public let sourcePath: ArchiveRelativePath
    public let expectedSourceHash: Data

    public init(
        frameID: UUID,
        capturedAt: Date,
        sourcePath: ArchiveRelativePath,
        expectedSourceHash: Data
    ) throws {
        let expectedSuffix = "/frames/\(frameID.uuidString.lowercased()).heic"
        guard sourcePath.rawValue.hasPrefix("media/"),
            sourcePath.rawValue.hasSuffix(expectedSuffix),
            expectedSourceHash.count == 32
        else {
            throw ThumbnailPipelineError.invalidSourcePath
        }
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.sourcePath = sourcePath
        self.expectedSourceHash = expectedSourceHash
    }
}

public enum ThumbnailGenerationDisposition: String, Codable, Equatable, Sendable {
    case generated
    case reused
    case rebuiltMissing
}

public struct ThumbnailGenerationResult: Equatable, Sendable {
    public let disposition: ThumbnailGenerationDisposition
    public let relativePath: ArchiveRelativePath
    public let contentHash: Data
    public let pixelSize: ThumbnailPixelSize?
    public let artifact: EnrichmentArtifact
}

public final class ThumbnailGenerator: @unchecked Sendable {
    private let fileStore: ArchiveFileStore
    private let decoder: any ThumbnailHEICDecoding
    private let encoder: any ThumbnailHEICEncoding
    private let producer: ProducerVersion
    private let now: @Sendable () -> Date
    private let artifactIDProvider: @Sendable (UUID) -> UUID

    public init(
        fileStore: ArchiveFileStore,
        decoder: any ThumbnailHEICDecoding,
        encoder: any ThumbnailHEICEncoding,
        producer: ProducerVersion,
        now: @escaping @Sendable () -> Date = Date.init,
        artifactIDProvider: @escaping @Sendable (UUID) -> UUID = { _ in UUID() }
    ) {
        self.fileStore = fileStore
        self.decoder = decoder
        self.encoder = encoder
        self.producer = producer
        self.now = now
        self.artifactIDProvider = artifactIDProvider
    }

    public func ensure(
        _ request: ThumbnailGenerationRequest,
        expectedThumbnailHash: Data?,
        databaseCommit: (EnrichmentArtifact) throws -> Void = { _ in }
    ) throws -> ThumbnailGenerationResult {
        let relativePath = try thumbnailPath(for: request)
        let finalURL = fileStore.url(for: relativePath)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            guard let expectedThumbnailHash, expectedThumbnailHash.count == 32 else {
                throw ThumbnailPipelineError.thumbnailIntegrityMismatch
            }
            let bytes = try Data(contentsOf: finalURL, options: .mappedIfSafe)
            let actualHash = sha256(bytes)
            guard actualHash == expectedThumbnailHash else {
                throw ThumbnailPipelineError.thumbnailIntegrityMismatch
            }
            let artifact = try makeArtifact(
                request: request,
                relativePath: relativePath,
                byteCount: bytes.count,
                contentHash: actualHash
            )
            return ThumbnailGenerationResult(
                disposition: .reused,
                relativePath: relativePath,
                contentHash: actualHash,
                pixelSize: nil,
                artifact: artifact
            )
        }

        let sourceURL = fileStore.url(for: request.sourcePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            throw ThumbnailPipelineError.sourceFileUnavailable
        }
        let sourceBytes = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard sha256(sourceBytes) == request.expectedSourceHash else {
            throw ThumbnailPipelineError.sourceIntegrityMismatch
        }
        let source = try decoder.decode(sourceBytes)
        let raster = try ThumbnailRasterizer().render(source)
        let encoded = try encoder.encode(raster)
        guard !encoded.isEmpty else { throw ThumbnailPipelineError.emptyEncodedThumbnail }
        let contentHash = sha256(encoded)
        if let expectedThumbnailHash, expectedThumbnailHash != contentHash {
            throw ThumbnailPipelineError.thumbnailIntegrityMismatch
        }
        var committedArtifact: EnrichmentArtifact?
        let integrity = try fileStore.write(encoded, to: relativePath) { integrity in
            let artifact = try self.makeArtifact(
                request: request,
                relativePath: relativePath,
                byteCount: Int(integrity.byteCount),
                contentHash: integrity.sha256
            )
            try databaseCommit(artifact)
            committedArtifact = artifact
        }
        guard let artifact = committedArtifact else {
            throw ThumbnailPipelineError.thumbnailIntegrityMismatch
        }
        return ThumbnailGenerationResult(
            disposition: expectedThumbnailHash == nil ? .generated : .rebuiltMissing,
            relativePath: relativePath,
            contentHash: integrity.sha256,
            pixelSize: raster.size,
            artifact: artifact
        )
    }

    public func delete(
        relativePath: ArchiveRelativePath,
        expectedHash: Data,
        databaseDelete: () throws -> Void = {}
    ) throws {
        guard relativePath.rawValue.hasPrefix("thumbnails/"),
            relativePath.rawValue.hasSuffix(".heic"),
            expectedHash.count == 32
        else {
            throw ThumbnailPipelineError.thumbnailIntegrityMismatch
        }
        let url = fileStore.url(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try databaseDelete()
            return
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard sha256(bytes) == expectedHash else {
            throw ThumbnailPipelineError.thumbnailIntegrityMismatch
        }
        try databaseDelete()
        try FileManager.default.removeItem(at: url)
    }

    private func thumbnailPath(for request: ThumbnailGenerationRequest) throws
        -> ArchiveRelativePath
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: request.capturedAt)
        guard let year = components.year, let month = components.month, let day = components.day
        else {
            throw ThumbnailPipelineError.invalidSourcePath
        }
        return try ArchiveRelativePath(
            String(
                format: "thumbnails/%04d/%02d/%02d/%@.heic",
                year,
                month,
                day,
                request.frameID.uuidString.lowercased()
            )
        )
    }

    private func makeArtifact(
        request: ThumbnailGenerationRequest,
        relativePath: ArchiveRelativePath,
        byteCount: Int,
        contentHash: Data
    ) throws -> EnrichmentArtifact {
        try EnrichmentArtifact(
            id: artifactIDProvider(request.frameID),
            frameID: request.frameID,
            kind: .thumbnail,
            producer: producer,
            createdAt: now(),
            payloadLocator: .relativeFileOffset(
                path: relativePath.rawValue,
                byteOffset: 0,
                byteLength: byteCount
            ),
            contentHash: contentHash,
            state: .ready
        )
    }

    private func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
