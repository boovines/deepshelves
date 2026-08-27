import Foundation

public enum SurfaceKind: String, Codable, Equatable, Sendable {
    case foregroundWindow
}

public enum ActivityState: String, Codable, Equatable, Sendable {
    case active
    case recentlyActive
    case idle
}

public enum CaptureReason: String, Codable, Equatable, Sendable {
    case visualChange
    case contextChange
    case heartbeat
    case manual
}

public final class PixelBufferHandle: @unchecked Sendable {
    public let object: AnyObject

    public init(object: AnyObject) {
        self.object = object
    }
}

public struct CaptureEnvelope: Codable, Sendable, ContractValidatable {
    public let id: UUID
    public let capturedAt: Date
    public let continuousTimeNanoseconds: UInt64
    public let displayID: UInt32
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let surfaceKind: SurfaceKind
    public let pixelSize: PixelSize
    public let foreground: ForegroundContext
    public let browser: BrowserContext?
    public let activity: ActivityState
    public let reason: CaptureReason
    public let policyDecisionID: UUID
    public let pixelBuffer: PixelBufferHandle?

    public init(
        id: UUID,
        capturedAt: Date,
        continuousTimeNanoseconds: UInt64,
        displayID: UInt32,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        surfaceKind: SurfaceKind,
        pixelSize: PixelSize,
        foreground: ForegroundContext,
        browser: BrowserContext?,
        activity: ActivityState,
        reason: CaptureReason,
        policyDecisionID: UUID,
        pixelBuffer: PixelBufferHandle? = nil
    ) throws {
        self.id = id
        self.capturedAt = capturedAt
        self.continuousTimeNanoseconds = continuousTimeNanoseconds
        self.displayID = displayID
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.surfaceKind = surfaceKind
        self.pixelSize = pixelSize
        self.foreground = foreground
        self.browser = browser
        self.activity = activity
        self.reason = reason
        self.policyDecisionID = policyDecisionID
        self.pixelBuffer = pixelBuffer
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            displayID > 0,
            field: "displayID",
            violation: .outOfRange,
            detail: "display identifier must be positive"
        )
        try ContractChecks.require(
            targetWindowID > 0,
            field: "targetWindowID",
            violation: .outOfRange,
            detail: "target window identifier must be positive"
        )
        try pixelSize.validate()
        try foreground.validate()
        try browser?.validate()
        try ContractChecks.require(
            browser?.isPrivateContext != true,
            field: "browser.isPrivateContext",
            violation: .inconsistent,
            detail: "private browser contexts cannot become pixel-bearing capture envelopes"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case capturedAt
        case continuousTimeNanoseconds
        case displayID
        case captureEpochID
        case targetWindowID
        case surfaceKind
        case pixelSize
        case foreground
        case browser
        case activity
        case reason
        case policyDecisionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        continuousTimeNanoseconds = try container.decode(
            UInt64.self, forKey: .continuousTimeNanoseconds)
        displayID = try container.decode(UInt32.self, forKey: .displayID)
        captureEpochID = try container.decode(UUID.self, forKey: .captureEpochID)
        targetWindowID = try container.decode(UInt32.self, forKey: .targetWindowID)
        surfaceKind = try container.decode(SurfaceKind.self, forKey: .surfaceKind)
        pixelSize = try container.decode(PixelSize.self, forKey: .pixelSize)
        foreground = try container.decode(ForegroundContext.self, forKey: .foreground)
        browser = try container.decodeIfPresent(BrowserContext.self, forKey: .browser)
        activity = try container.decode(ActivityState.self, forKey: .activity)
        reason = try container.decode(CaptureReason.self, forKey: .reason)
        policyDecisionID = try container.decode(UUID.self, forKey: .policyDecisionID)
        pixelBuffer = nil
    }
}

extension CaptureEnvelope: Equatable {
    public static func == (lhs: CaptureEnvelope, rhs: CaptureEnvelope) -> Bool {
        lhs.id == rhs.id && lhs.capturedAt == rhs.capturedAt
            && lhs.continuousTimeNanoseconds == rhs.continuousTimeNanoseconds
            && lhs.displayID == rhs.displayID && lhs.captureEpochID == rhs.captureEpochID
            && lhs.targetWindowID == rhs.targetWindowID && lhs.surfaceKind == rhs.surfaceKind
            && lhs.pixelSize == rhs.pixelSize && lhs.foreground == rhs.foreground
            && lhs.browser == rhs.browser && lhs.activity == rhs.activity
            && lhs.reason == rhs.reason && lhs.policyDecisionID == rhs.policyDecisionID
            && compareHandles(lhs.pixelBuffer, rhs.pixelBuffer)
    }

    private static func compareHandles(_ lhs: PixelBufferHandle?, _ rhs: PixelBufferHandle?) -> Bool
    {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let lhs?, let rhs?): lhs === rhs
        default: false
        }
    }
}
