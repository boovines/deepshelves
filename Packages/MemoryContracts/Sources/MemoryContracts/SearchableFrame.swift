import Foundation

public enum EnrichmentState: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case failed
    case suppressed
}

public struct SearchableFrame: Codable, Equatable, Sendable, ContractValidatable {
    public let id: UUID
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let capturedAt: Date
    public let chunkID: UUID
    public let presentationTimeMS: Int64
    public let thumbnailPath: String?
    public let foreground: ForegroundContext
    public let browser: BrowserContext?
    public let textState: EnrichmentState
    public let visualState: EnrichmentState
    public let isTransition: Bool
    public let schemaVersion: Int

    public init(
        id: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        capturedAt: Date,
        chunkID: UUID,
        presentationTimeMS: Int64,
        thumbnailPath: String?,
        foreground: ForegroundContext,
        browser: BrowserContext?,
        textState: EnrichmentState,
        visualState: EnrichmentState,
        isTransition: Bool,
        schemaVersion: Int
    ) throws {
        self.id = id
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.capturedAt = capturedAt
        self.chunkID = chunkID
        self.presentationTimeMS = presentationTimeMS
        self.thumbnailPath = thumbnailPath
        self.foreground = foreground
        self.browser = browser
        self.textState = textState
        self.visualState = visualState
        self.isTransition = isTransition
        self.schemaVersion = schemaVersion
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            targetWindowID > 0,
            field: "searchableFrame.targetWindowID",
            violation: .outOfRange,
            detail: "target window identifier must be positive"
        )
        try ContractChecks.require(
            presentationTimeMS >= 0,
            field: "searchableFrame.presentationTimeMS",
            violation: .outOfRange,
            detail: "presentation time cannot be negative"
        )
        if let thumbnailPath {
            try ContractChecks.validateRelativePath(
                thumbnailPath, field: "searchableFrame.thumbnailPath")
            try ContractChecks.require(
                thumbnailPath.hasPrefix("thumbnails/") && thumbnailPath.hasSuffix(".heic"),
                field: "searchableFrame.thumbnailPath",
                violation: .inconsistent,
                detail: "V1 thumbnails live below thumbnails/ and use HEIC"
            )
        }
        try foreground.validate()
        try browser?.validate()
        try ContractChecks.require(
            browser?.isPrivateContext != true,
            field: "searchableFrame.browser.isPrivateContext",
            violation: .inconsistent,
            detail: "private browser context cannot be projected into a searchable frame"
        )
        try ContractChecks.requireSchemaVersion(schemaVersion)
    }
}
