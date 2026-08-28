import Foundation

public struct HEICKeyframeEntry: Codable, Equatable, Sendable, ContractValidatable {
    public let frameID: UUID
    public let presentationTimeMS: Int64
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: Data

    public init(
        frameID: UUID,
        presentationTimeMS: Int64,
        relativePath: String,
        byteCount: Int64,
        sha256: Data
    ) throws {
        self.frameID = frameID
        self.presentationTimeMS = presentationTimeMS
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            presentationTimeMS >= 0 && presentationTimeMS <= 30_000,
            field: "heicKeyframeEntry.presentationTimeMS",
            violation: .outOfRange,
            detail: "logical presentation time must be within a 30-second chunk"
        )
        try ContractChecks.validateRelativePath(
            relativePath,
            field: "heicKeyframeEntry.relativePath"
        )
        let expectedPath = "frames/\(frameID.uuidString.lowercased()).heic"
        try ContractChecks.require(
            relativePath == expectedPath,
            field: "heicKeyframeEntry.relativePath",
            violation: .inconsistent,
            detail: "frame asset path must be derived from the immutable frame identity"
        )
        try ContractChecks.require(
            byteCount > 0,
            field: "heicKeyframeEntry.byteCount",
            violation: .outOfRange,
            detail: "a canonical source frame cannot be empty"
        )
        try ContractChecks.require(
            sha256.count == 32,
            field: "heicKeyframeEntry.sha256",
            violation: .outOfRange,
            detail: "frame SHA-256 must contain exactly 32 bytes"
        )
    }

    public func archiveRelativePath(chunkManifestPath: String) throws -> String {
        try ContractChecks.validateRelativePath(
            chunkManifestPath,
            field: "heicKeyframeEntry.chunkManifestPath"
        )
        try ContractChecks.require(
            chunkManifestPath.hasPrefix("media/")
                && chunkManifestPath.hasSuffix("/manifest.json"),
            field: "heicKeyframeEntry.chunkManifestPath",
            violation: .inconsistent,
            detail: "HEIC chunk manifest must live below media/ and end in manifest.json"
        )
        return String(chunkManifestPath.dropLast("manifest.json".count)) + relativePath
    }
}

public struct HEICKeyframeManifest: Codable, Equatable, Sendable, ContractValidatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let chunkID: UUID
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let width: Int
    public let height: Int
    public let frames: [HEICKeyframeEntry]

    public init(
        chunkID: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        width: Int,
        height: Int,
        frames: [HEICKeyframeEntry]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.chunkID = chunkID
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.width = width
        self.height = height
        self.frames = frames
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            schemaVersion == Self.currentSchemaVersion,
            field: "heicKeyframeManifest.schemaVersion",
            violation: .unsupportedVersion,
            detail: "only HEIC keyframe manifest version 2 is supported"
        )
        try ContractChecks.require(
            targetWindowID > 0,
            field: "heicKeyframeManifest.targetWindowID",
            violation: .outOfRange,
            detail: "target window identifier must be positive"
        )
        _ = try PixelSize(width: width, height: height)
        try ContractChecks.require(
            !frames.isEmpty,
            field: "heicKeyframeManifest.frames",
            violation: .empty,
            detail: "a ready logical chunk must contain at least one frame"
        )
        for frame in frames {
            try frame.validate()
        }
        try ContractChecks.require(
            frames.first?.presentationTimeMS == 0,
            field: "heicKeyframeManifest.frames",
            violation: .inconsistent,
            detail: "the first logical presentation time must be zero"
        )
        try ContractChecks.require(
            zip(frames, frames.dropFirst()).allSatisfy {
                $0.presentationTimeMS < $1.presentationTimeMS
            },
            field: "heicKeyframeManifest.frames",
            violation: .inconsistent,
            detail: "frame logical presentation times must be strictly increasing"
        )
        try ContractChecks.require(
            Set(frames.map(\.frameID)).count == frames.count
                && Set(frames.map(\.relativePath)).count == frames.count,
            field: "heicKeyframeManifest.frames",
            violation: .duplicateValue,
            detail: "frame identities and paths must be unique"
        )
    }
}
