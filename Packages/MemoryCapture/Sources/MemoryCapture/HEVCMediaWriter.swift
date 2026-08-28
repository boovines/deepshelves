@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

public struct HEVCEncodingProfile: Equatable, Sendable {
    public let codecFourCC: String
    public let requiresHardwareAcceleration: Bool
    public let fragmentIntervalNanoseconds: UInt64
    public let keyFrameIntervalSeconds: Double
    public let averageBitRate: Int

    public static let production = HEVCEncodingProfile(
        codecFourCC: "hvc1",
        requiresHardwareAcceleration: true,
        fragmentIntervalNanoseconds: 1_000_000_000,
        keyFrameIntervalSeconds: 1,
        averageBitRate: 2_000_000
    )
}

public enum HEVCMediaWriterError: Error, Equatable, Sendable {
    case invalidDimensions
    case destinationAlreadyExists
    case partialAlreadyExists
    case scopeMismatch
    case missingImageBuffer
    case invalidPresentationTime
    case nonIncreasingPresentationTime
    case maximumDurationExceeded
    case cannotAddVideoInput
    case startWritingFailed(String)
    case adaptorPixelBufferPoolUnavailable
    case pixelBufferAllocationFailed(Int32)
    case pixelTransferSessionFailed(Int32)
    case pixelTransferFailed(Int32)
    case bufferRetentionClosed
    case appendFailed(String)
    case finishFailed(String)
    case validationFailed(String)
    case alreadyFinalized
}

public final class HEVCMediaWriter: @unchecked Sendable {
    public let outputURL: URL
    public let partialURL: URL
    public let chunkID: UUID
    public let scope: MediaChunkScope
    public let dimensions: PixelSize

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let profile: HEVCEncodingProfile
    private let retainedAdaptorBuffers = MediaBufferRetentionLedger<CVPixelBuffer>()
    private var transferSession: VTPixelTransferSession?
    private var core: MediaWriterCore
    private var started = false
    private var finalized = false
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?

    public init(
        outputURL: URL,
        chunkID: UUID = UUID(),
        scope: MediaChunkScope,
        profile: HEVCEncodingProfile = .production
    ) throws {
        guard Self.valid(scope.dimensions) else {
            throw HEVCMediaWriterError.invalidDimensions
        }
        self.outputURL = outputURL
        self.chunkID = chunkID
        self.scope = scope
        dimensions = scope.dimensions
        self.profile = profile
        core = try MediaWriterCore(chunkID: chunkID, scope: scope)
        partialURL = MediaChunkPublisher.partialURL(for: outputURL)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            throw HEVCMediaWriterError.destinationAlreadyExists
        }
        if fileManager.fileExists(atPath: partialURL.path) {
            throw HEVCMediaWriterError.partialAlreadyExists
        }
        if !fileManager.fileExists(atPath: outputURL.deletingLastPathComponent().path) {
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let createdWriter = try AVAssetWriter(outputURL: partialURL, fileType: .mov)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: profile.averageBitRate,
            AVVideoExpectedSourceFrameRateKey: 1,
            AVVideoMaxKeyFrameIntervalDurationKey: profile.keyFrameIntervalSeconds,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
        ]
        let encoderSpecification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: encoderSpecification,
        ]
        let createdInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        createdInput.expectsMediaDataInRealTime = true
        createdInput.mediaTimeScale = 1_000
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: dimensions.width,
            kCVPixelBufferHeightKey: dimensions.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let createdAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: createdInput,
            sourcePixelBufferAttributes: poolAttributes as [String: Any]
        )
        guard createdWriter.canAdd(createdInput) else {
            throw HEVCMediaWriterError.cannotAddVideoInput
        }
        createdWriter.add(createdInput)
        createdWriter.movieTimeScale = 1_000
        createdWriter.movieFragmentInterval = CMTime(
            value: CMTimeValue(profile.fragmentIntervalNanoseconds / 1_000_000),
            timescale: 1_000
        )
        createdWriter.initialMovieFragmentInterval = createdWriter.movieFragmentInterval
        writer = createdWriter
        input = createdInput
        adaptor = createdAdaptor
    }

    public func append(
        _ sampleBuffer: CMSampleBuffer,
        frameID: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32
    ) throws -> MediaFrameLocator? {
        guard !finalized else {
            throw HEVCMediaWriterError.alreadyFinalized
        }
        guard let sourceImage = sampleBuffer.imageBuffer else {
            throw HEVCMediaWriterError.missingImageBuffer
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, !presentationTime.isIndefinite else {
            throw HEVCMediaWriterError.invalidPresentationTime
        }
        let sourceDimensions = PixelSize(
            width: CVPixelBufferGetWidth(sourceImage),
            height: CVPixelBufferGetHeight(sourceImage)
        )
        let plan: MediaWriterAppendPlan
        do {
            plan = try core.planAppend(
                frameID: frameID,
                captureEpochID: captureEpochID,
                targetWindowID: targetWindowID,
                sourceDimensions: sourceDimensions,
                sourcePresentationTimeMilliseconds: Self.milliseconds(presentationTime)
            )
        } catch let error as MediaWriterCoreError {
            throw Self.writerError(for: error)
        }

        if !started {
            guard writer.startWriting() else {
                throw HEVCMediaWriterError.startWritingFailed(
                    writer.error?.localizedDescription ?? "unknown"
                )
            }
            writer.startSession(atSourceTime: presentationTime)
            started = true
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: partialURL.path
            )
        }
        guard input.isReadyForMoreMediaData else {
            return nil
        }

        let adaptorBuffer = try makeAdaptorBuffer(from: sourceImage)
        guard adaptor.append(adaptorBuffer, withPresentationTime: presentationTime) else {
            throw HEVCMediaWriterError.appendFailed(writer.error?.localizedDescription ?? "unknown")
        }
        do {
            try retainedAdaptorBuffers.retainAccepted(adaptorBuffer)
        } catch {
            throw HEVCMediaWriterError.bufferRetentionClosed
        }

        do {
            try core.recordAccepted(plan)
        } catch let error as MediaWriterCoreError {
            throw Self.writerError(for: error)
        }
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
        }
        lastPresentationTime = presentationTime
        return plan.locator
    }

    @discardableResult
    public func finish() async throws -> HEVCMediaChunkFinalization? {
        guard !finalized else {
            throw HEVCMediaWriterError.alreadyFinalized
        }
        finalized = true
        guard started else {
            writer.cancelWriting()
            retainedAdaptorBuffers.releaseAfterFinalization()
            try? FileManager.default.removeItem(at: partialURL)
            return nil
        }
        defer { retainedAdaptorBuffers.releaseAfterFinalization() }

        if let firstPresentationTime, let lastPresentationTime {
            let nominalEnd = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 2))
            let maximumEnd = CMTimeAdd(
                firstPresentationTime, CMTime(seconds: 30, preferredTimescale: 1_000))
            writer.endSession(
                atSourceTime: CMTimeCompare(nominalEnd, maximumEnd) <= 0 ? nominalEnd : maximumEnd
            )
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            cleanupPartial()
            throw HEVCMediaWriterError.finishFailed(
                writer.error?.localizedDescription ?? "unknown"
            )
        }

        do {
            let validation = try await validatePartial()
            let integrity = try MediaChunkPublisher.publish(
                partialURL: partialURL,
                outputURL: outputURL
            )
            return try core.finalization(
                outputURL: outputURL,
                codecFourCC: validation.codecFourCC,
                hardwareAccelerationRequired: profile.requiresHardwareAcceleration,
                integrity: integrity
            )
        } catch {
            cleanupPartial()
            throw error
        }
    }

    public func cancel() {
        guard !finalized else {
            return
        }
        finalized = true
        writer.cancelWriting()
        retainedAdaptorBuffers.releaseAfterFinalization()
        cleanupPartial()
    }

    deinit {
        guard !finalized else {
            return
        }
        writer.cancelWriting()
        retainedAdaptorBuffers.releaseAfterFinalization()
        cleanupPartial()
    }

    private func makeAdaptorBuffer(from sourceImage: CVPixelBuffer) throws -> CVPixelBuffer {
        let sourceDimensions = PixelSize(
            width: CVPixelBufferGetWidth(sourceImage),
            height: CVPixelBufferGetHeight(sourceImage)
        )
        guard sourceDimensions.width >= dimensions.width,
            sourceDimensions.height >= dimensions.height
        else {
            throw HEVCMediaWriterError.invalidDimensions
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw HEVCMediaWriterError.adaptorPixelBufferPoolUnavailable
        }
        var destination: CVPixelBuffer?
        let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &destination
        )
        guard allocationStatus == kCVReturnSuccess, let destination else {
            throw HEVCMediaWriterError.pixelBufferAllocationFailed(allocationStatus)
        }
        let session = try pixelTransferSession()
        let transferStatus = VTPixelTransferSessionTransferImage(
            session,
            from: sourceImage,
            to: destination
        )
        guard transferStatus == noErr else {
            throw HEVCMediaWriterError.pixelTransferFailed(transferStatus)
        }
        return destination
    }

    private func pixelTransferSession() throws -> VTPixelTransferSession {
        if let transferSession {
            return transferSession
        }
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        )
        guard status == noErr, let session else {
            throw HEVCMediaWriterError.pixelTransferSessionFailed(status)
        }
        let propertyStatus = VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Normal
        )
        guard propertyStatus == noErr else {
            throw HEVCMediaWriterError.pixelTransferSessionFailed(propertyStatus)
        }
        transferSession = session
        return session
    }

    private func validatePartial() async throws -> (codecFourCC: String, duration: CMTime) {
        let asset = AVURLAsset(url: partialURL)
        guard try await asset.load(.isPlayable) else {
            throw HEVCMediaWriterError.validationFailed("asset is not playable")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw HEVCMediaWriterError.validationFailed("expected exactly one video track")
        }
        let naturalSize = try await track.load(.naturalSize)
        guard Int(naturalSize.width) == dimensions.width,
            Int(naturalSize.height) == dimensions.height
        else {
            throw HEVCMediaWriterError.validationFailed("encoded dimensions do not match scope")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw HEVCMediaWriterError.validationFailed("video track has no format description")
        }
        let codec = Self.fourCC(CMFormatDescriptionGetMediaSubType(description))
        guard codec == profile.codecFourCC else {
            throw HEVCMediaWriterError.validationFailed("unexpected codec \(codec)")
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds <= 30.001 else {
            throw HEVCMediaWriterError.maximumDurationExceeded
        }
        return (codec, duration)
    }

    private func cleanupPartial() {
        if FileManager.default.fileExists(atPath: partialURL.path) {
            try? FileManager.default.removeItem(at: partialURL)
        }
    }

    private static func valid(_ dimensions: PixelSize) -> Bool {
        dimensions.width >= 2 && dimensions.height >= 2 && dimensions.width.isMultiple(of: 2)
            && dimensions.height.isMultiple(of: 2)
            && max(dimensions.width, dimensions.height) <= CaptureConstants.maximumLongEdge
    }

    private static func milliseconds(_ time: CMTime) -> Int64 {
        Int64((time.seconds * 1_000).rounded())
    }

    private static func writerError(for error: MediaWriterCoreError) -> HEVCMediaWriterError {
        switch error {
        case .invalidDestinationDimensions, .invalidSourceDimensions,
            .aspectRatioMismatch, .upscalingForbidden:
            .invalidDimensions
        case .scopeMismatch:
            .scopeMismatch
        case .invalidPresentationTime:
            .invalidPresentationTime
        case .nonIncreasingPresentationTime:
            .nonIncreasingPresentationTime
        case .maximumDurationExceeded:
            .maximumDurationExceeded
        case .staleAppendPlan:
            .appendFailed("stale media append plan")
        case .emptyChunk:
            .validationFailed("media chunk has no accepted frames")
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
