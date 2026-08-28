import Foundation

public enum MediaCodec: String, Codable, Equatable, Sendable {
    case hevcMain
    case heicKeyframes
}

public enum MediaContainer: String, Codable, Equatable, Sendable {
    case quickTimeMovie
    case heicKeyframeDirectory
}

public enum MediaChunkState: String, Codable, Equatable, Sendable {
    case writing
    case ready
    case rewriting
    case quarantined
}

public struct MediaChunk: Codable, Equatable, Sendable, ContractValidatable {
    public let id: UUID
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let relativePath: String
    public let startedAt: Date
    public let endedAt: Date
    public let codec: MediaCodec
    public let container: MediaContainer
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let byteCount: Int64
    public let sha256: Data
    public let state: MediaChunkState

    public init(
        id: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        relativePath: String,
        startedAt: Date,
        endedAt: Date,
        codec: MediaCodec,
        container: MediaContainer,
        width: Int,
        height: Int,
        frameCount: Int,
        byteCount: Int64,
        sha256: Data,
        state: MediaChunkState
    ) throws {
        self.id = id
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.relativePath = relativePath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.codec = codec
        self.container = container
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.byteCount = byteCount
        self.sha256 = sha256
        self.state = state
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            targetWindowID > 0,
            field: "mediaChunk.targetWindowID",
            violation: .outOfRange,
            detail: "target window identifier must be positive"
        )
        try ContractChecks.validateRelativePath(relativePath, field: "mediaChunk.relativePath")
        let validRepresentation =
            switch (codec, container) {
            case (.hevcMain, .quickTimeMovie):
                relativePath.hasPrefix("media/") && relativePath.hasSuffix(".mov")
            case (.heicKeyframes, .heicKeyframeDirectory):
                relativePath.hasPrefix("media/") && relativePath.hasSuffix("/manifest.json")
            default:
                false
            }
        try ContractChecks.require(
            validRepresentation,
            field: "mediaChunk.representation",
            violation: .inconsistent,
            detail: "codec, container, and archive path must identify one supported representation"
        )
        try ContractChecks.validateInterval(
            DateInterval(start: startedAt, end: endedAt),
            field: "mediaChunk.interval",
            maximumDuration: 30
        )
        _ = try PixelSize(width: width, height: height)
        try ContractChecks.require(
            frameCount >= 0 && byteCount >= 0,
            field: "mediaChunk.counts",
            violation: .outOfRange,
            detail: "frame and byte counts cannot be negative"
        )
        if state == .ready {
            try ContractChecks.require(
                frameCount > 0 && byteCount > 0 && sha256.count == 32,
                field: "mediaChunk.readyIntegrity",
                violation: .missingRequiredValue,
                detail: "ready chunks require frames, final byte count, and a SHA-256 digest"
            )
        } else if !sha256.isEmpty {
            try ContractChecks.require(
                sha256.count == 32,
                field: "mediaChunk.sha256",
                violation: .outOfRange,
                detail: "SHA-256 digest must contain exactly 32 bytes"
            )
        }
    }
}
