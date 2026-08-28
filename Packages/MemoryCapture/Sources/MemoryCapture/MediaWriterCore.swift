import Foundation

public struct MediaFrameLocator: Equatable, Sendable {
    public let frameID: UUID
    public let chunkID: UUID
    public let presentationTimeMilliseconds: Int64

    public init(frameID: UUID, chunkID: UUID, presentationTimeMilliseconds: Int64) {
        self.frameID = frameID
        self.chunkID = chunkID
        self.presentationTimeMilliseconds = presentationTimeMilliseconds
    }
}

public struct HEVCMediaChunkFinalization: Equatable, Sendable {
    public let chunkID: UUID
    public let scope: MediaChunkScope
    public let outputURL: URL
    public let codecFourCC: String
    public let hardwareAccelerationRequired: Bool
    public let durationMilliseconds: Int64
    public let frameCount: Int
    public let byteCount: Int64
    public let sha256: Data
    public let locators: [MediaFrameLocator]

    public var sha256Hex: String {
        sha256.map { String(format: "%02x", $0) }.joined()
    }

    public var presentationTimeMilliseconds: [Int64] {
        locators.map(\.presentationTimeMilliseconds)
    }
}

public enum MediaWriterCoreError: Error, Equatable, Sendable {
    case invalidDestinationDimensions
    case invalidSourceDimensions
    case scopeMismatch
    case aspectRatioMismatch
    case upscalingForbidden
    case invalidPresentationTime
    case nonIncreasingPresentationTime
    case maximumDurationExceeded
    case staleAppendPlan
    case emptyChunk
}

public enum MediaBufferRetentionError: Error, Equatable, Sendable {
    case finalizationCompleted
}

public final class MediaBufferRetentionLedger<Buffer>: @unchecked Sendable {
    public private(set) var retainedCount = 0

    private var retainedBuffers: [Buffer] = []
    private var finalizationCompleted = false

    public init() {}

    public func retainAccepted(_ buffer: Buffer) throws {
        guard !finalizationCompleted else {
            throw MediaBufferRetentionError.finalizationCompleted
        }
        retainedBuffers.append(buffer)
        retainedCount = retainedBuffers.count
    }

    public func releaseAfterFinalization() {
        guard !finalizationCompleted else {
            return
        }
        finalizationCompleted = true
        retainedBuffers.removeAll()
        retainedCount = 0
    }
}

public struct MediaDownscalePlan: Equatable, Sendable {
    public let sourceDimensions: PixelSize
    public let destinationDimensions: PixelSize

    public var requiresScaling: Bool {
        sourceDimensions != destinationDimensions
    }
}

public struct MediaWriterAppendPlan: Equatable, Sendable {
    public let locator: MediaFrameLocator
    public let sourcePresentationTimeMilliseconds: Int64
    public let downscale: MediaDownscalePlan

    fileprivate let sequence: Int
}

public struct MediaWriterCore: Sendable {
    public let chunkID: UUID
    public let scope: MediaChunkScope

    public private(set) var locators: [MediaFrameLocator] = []
    private var firstPresentationTimeMilliseconds: Int64?
    private var lastPresentationTimeMilliseconds: Int64?

    public var durationMilliseconds: Int64 {
        locators.last?.presentationTimeMilliseconds ?? 0
    }

    public var frameCount: Int {
        locators.count
    }

    public init(chunkID: UUID, scope: MediaChunkScope) throws {
        guard Self.validDestination(scope.dimensions) else {
            throw MediaWriterCoreError.invalidDestinationDimensions
        }
        self.chunkID = chunkID
        self.scope = scope
    }

    public func planAppend(
        frameID: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        sourceDimensions: PixelSize,
        sourcePresentationTimeMilliseconds: Int64
    ) throws -> MediaWriterAppendPlan {
        guard captureEpochID == scope.epochID, targetWindowID == scope.targetWindowID else {
            throw MediaWriterCoreError.scopeMismatch
        }
        guard sourceDimensions.width > 0, sourceDimensions.height > 0 else {
            throw MediaWriterCoreError.invalidSourceDimensions
        }
        guard sourceDimensions.width >= scope.dimensions.width,
            sourceDimensions.height >= scope.dimensions.height
        else {
            throw MediaWriterCoreError.upscalingForbidden
        }
        guard Self.aspectRatiosMatch(sourceDimensions, scope.dimensions) else {
            throw MediaWriterCoreError.aspectRatioMismatch
        }
        guard sourcePresentationTimeMilliseconds >= 0 else {
            throw MediaWriterCoreError.invalidPresentationTime
        }
        if let lastPresentationTimeMilliseconds,
            sourcePresentationTimeMilliseconds <= lastPresentationTimeMilliseconds
        {
            throw MediaWriterCoreError.nonIncreasingPresentationTime
        }
        let first = firstPresentationTimeMilliseconds ?? sourcePresentationTimeMilliseconds
        let relative = sourcePresentationTimeMilliseconds - first
        guard relative <= 30_000 else {
            throw MediaWriterCoreError.maximumDurationExceeded
        }
        return MediaWriterAppendPlan(
            locator: MediaFrameLocator(
                frameID: frameID,
                chunkID: chunkID,
                presentationTimeMilliseconds: relative
            ),
            sourcePresentationTimeMilliseconds: sourcePresentationTimeMilliseconds,
            downscale: MediaDownscalePlan(
                sourceDimensions: sourceDimensions,
                destinationDimensions: scope.dimensions
            ),
            sequence: locators.count
        )
    }

    public mutating func recordAccepted(_ plan: MediaWriterAppendPlan) throws {
        guard plan.sequence == locators.count,
            plan.locator.chunkID == chunkID,
            plan.locator.presentationTimeMilliseconds == plan.sourcePresentationTimeMilliseconds
                - (firstPresentationTimeMilliseconds ?? plan.sourcePresentationTimeMilliseconds)
        else {
            throw MediaWriterCoreError.staleAppendPlan
        }
        if firstPresentationTimeMilliseconds == nil {
            firstPresentationTimeMilliseconds = plan.sourcePresentationTimeMilliseconds
        }
        lastPresentationTimeMilliseconds = plan.sourcePresentationTimeMilliseconds
        locators.append(plan.locator)
    }

    public func finalization(
        outputURL: URL,
        codecFourCC: String,
        hardwareAccelerationRequired: Bool,
        integrity: PublishedMediaIntegrity
    ) throws -> HEVCMediaChunkFinalization {
        guard !locators.isEmpty else {
            throw MediaWriterCoreError.emptyChunk
        }
        return HEVCMediaChunkFinalization(
            chunkID: chunkID,
            scope: scope,
            outputURL: outputURL,
            codecFourCC: codecFourCC,
            hardwareAccelerationRequired: hardwareAccelerationRequired,
            durationMilliseconds: durationMilliseconds,
            frameCount: frameCount,
            byteCount: integrity.byteCount,
            sha256: integrity.sha256,
            locators: locators
        )
    }

    private static func validDestination(_ dimensions: PixelSize) -> Bool {
        dimensions.width >= 2 && dimensions.height >= 2 && dimensions.width.isMultiple(of: 2)
            && dimensions.height.isMultiple(of: 2)
            && max(dimensions.width, dimensions.height) <= CaptureConstants.maximumLongEdge
    }

    private static func aspectRatiosMatch(_ source: PixelSize, _ destination: PixelSize) -> Bool {
        let crossProductDifference = abs(
            Double(source.width * destination.height - source.height * destination.width)
        )
        let scale = Double(
            max(source.width * destination.height, source.height * destination.width))
        return scale > 0 && crossProductDifference / scale <= 0.002
    }
}
