@preconcurrency import AVFoundation
import CoreMedia
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
    case cannotAddVideoInput
    case startWritingFailed(String)
    case appendFailed(String)
    case finishFailed(String)
}

public final class HEVCMediaWriter: @unchecked Sendable {
    public let outputURL: URL
    public let partialURL: URL
    public let dimensions: PixelSize

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false

    public init(
        outputURL: URL,
        dimensions: PixelSize,
        profile: HEVCEncodingProfile = .production
    ) throws {
        self.outputURL = outputURL
        self.dimensions = dimensions
        partialURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).partial.mov"
        )
        if FileManager.default.fileExists(atPath: partialURL.path) {
            try FileManager.default.removeItem(at: partialURL)
        }
        writer = try AVAssetWriter(outputURL: partialURL, fileType: .mov)

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
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw HEVCMediaWriterError.cannotAddVideoInput
        }
        writer.add(input)
        writer.movieFragmentInterval = CMTime(
            value: CMTimeValue(profile.fragmentIntervalNanoseconds / 1_000_000),
            timescale: 1_000
        )
        writer.initialMovieFragmentInterval = writer.movieFragmentInterval
    }

    public func append(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        if !started {
            guard writer.startWriting() else {
                throw HEVCMediaWriterError.startWritingFailed(writer.error?.localizedDescription ?? "unknown")
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        guard input.isReadyForMoreMediaData else {
            return false
        }
        guard input.append(sampleBuffer) else {
            throw HEVCMediaWriterError.appendFailed(writer.error?.localizedDescription ?? "unknown")
        }
        return true
    }

    public func finish() async throws {
        guard started else {
            writer.cancelWriting()
            return
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw HEVCMediaWriterError.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: partialURL, to: outputURL)
    }
}
