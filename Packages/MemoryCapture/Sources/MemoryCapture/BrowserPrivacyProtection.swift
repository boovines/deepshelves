import Foundation
import MemoryContracts

public struct CapturePermissionObservation: Codable, Equatable, Sendable {
    public let screenRecordingGranted: Bool
    public let accessibilityGranted: Bool

    public init(screenRecordingGranted: Bool, accessibilityGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
    }
}

public protocol CapturePermissionHealthProbing: Sendable {
    func currentObservation() -> CapturePermissionObservation
}

public struct SystemCapturePermissionHealthProbe: CapturePermissionHealthProbing {
    public init() {}

    public func currentObservation() -> CapturePermissionObservation {
        let current = CaptureCapabilities.current()
        return CapturePermissionObservation(
            screenRecordingGranted: current.screenRecording,
            accessibilityGranted: current.accessibility
        )
    }
}

public enum CapturePermissionHealthState: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case revoked
}

public struct CapturePermissionHealthSnapshot: Codable, Equatable, Sendable {
    public let screenRecording: CapturePermissionHealthState
    public let accessibility: CapturePermissionHealthState
    public let refreshCount: UInt64
    public let systemPromptWasRequested: Bool

    public init(
        screenRecording: CapturePermissionHealthState,
        accessibility: CapturePermissionHealthState,
        refreshCount: UInt64,
        systemPromptWasRequested: Bool
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.refreshCount = refreshCount
        self.systemPromptWasRequested = systemPromptWasRequested
    }

    public var recordingAvailable: Bool {
        screenRecording == .granted
    }

    public var protectedBrowserContextAvailable: Bool {
        accessibility == .granted
    }

    public var recordingUserVisibleReason: String? {
        switch screenRecording {
        case .granted:
            nil
        case .denied:
            "Recording paused because Screen Recording permission is required."
        case .revoked:
            "Recording paused because Screen Recording permission was revoked."
        }
    }

    public var protectedBrowserUserVisibleReason: String? {
        switch accessibility {
        case .granted:
            nil
        case .denied:
            "Browser capture paused to protect site exclusions because Accessibility permission is required."
        case .revoked:
            "Browser capture paused to protect site exclusions because Accessibility permission was revoked."
        }
    }
}

public actor CapturePermissionHealthMonitor {
    private let probe: any CapturePermissionHealthProbing
    private var observedScreenRecordingGrant = false
    private var observedAccessibilityGrant = false
    private var refreshCount: UInt64 = 0

    public init(
        probe: any CapturePermissionHealthProbing = SystemCapturePermissionHealthProbe()
    ) {
        self.probe = probe
    }

    public func refresh() -> CapturePermissionHealthSnapshot {
        refresh(observation: probe.currentObservation())
    }

    public func refresh(
        observation: CapturePermissionObservation
    ) -> CapturePermissionHealthSnapshot {
        refreshCount &+= 1
        let screenRecording = Self.state(
            isGranted: observation.screenRecordingGranted,
            wasGranted: observedScreenRecordingGrant
        )
        let accessibility = Self.state(
            isGranted: observation.accessibilityGranted,
            wasGranted: observedAccessibilityGrant
        )
        observedScreenRecordingGrant =
            observedScreenRecordingGrant || observation.screenRecordingGranted
        observedAccessibilityGrant =
            observedAccessibilityGrant || observation.accessibilityGranted
        return CapturePermissionHealthSnapshot(
            screenRecording: screenRecording,
            accessibility: accessibility,
            refreshCount: refreshCount,
            systemPromptWasRequested: false
        )
    }

    private static func state(
        isGranted: Bool,
        wasGranted: Bool
    ) -> CapturePermissionHealthState {
        if isGranted { return .granted }
        return wasGranted ? .revoked : .denied
    }
}

public enum BrowserProtectionIssue: String, Codable, Equatable, Sendable {
    case screenRecordingPermissionDenied
    case screenRecordingPermissionRevoked
    case accessibilityPermissionDenied
    case accessibilityPermissionRevoked
    case privateContextExcluded
    case protectedURLContextUnavailable
    case browserVersionChanged
}

public struct BrowserProtectionProjection: Equatable, Sendable, Encodable {
    public let browserContext: BrowserContextResolution
    public let issue: BrowserProtectionIssue?
    public let userVisibleReason: String?
    public let timelineGapReason: RecordingGapReason?

    public var isCaptureAllowed: Bool { issue == nil }
    public var contentFieldCount: Int { 0 }

    public init(
        browserContext: BrowserContextResolution,
        issue: BrowserProtectionIssue?,
        userVisibleReason: String?,
        timelineGapReason: RecordingGapReason?
    ) {
        self.browserContext = browserContext
        self.issue = issue
        self.userVisibleReason = userVisibleReason
        self.timelineGapReason = timelineGapReason
    }

    private enum CodingKeys: String, CodingKey {
        case issue
        case userVisibleReason
        case timelineGapReason
        case isCaptureAllowed
        case contentFieldCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(issue, forKey: .issue)
        try container.encodeIfPresent(userVisibleReason, forKey: .userVisibleReason)
        try container.encodeIfPresent(timelineGapReason, forKey: .timelineGapReason)
        try container.encode(isCaptureAllowed, forKey: .isCaptureAllowed)
        try container.encode(contentFieldCount, forKey: .contentFieldCount)
    }
}

public enum BrowserProtectionExposureGate {
    public static func project<Value>(
        _ value: Value,
        projection: BrowserProtectionProjection
    ) -> Value? {
        projection.isCaptureAllowed ? value : nil
    }
}

public actor ProtectedBrowserContextCoordinator {
    private let registry: BrowserAdapterRegistry
    private var observedVersions: [String: String] = [:]

    public init(registry: BrowserAdapterRegistry = .production) {
        self.registry = registry
    }

    public func evaluate(
        bundleIdentifier: String,
        applicationVersion: String?,
        rawResolution: BrowserContextResolution,
        permissionHealth: CapturePermissionHealthSnapshot,
        privateBrowserHandling: PrivateBrowserHandling,
        hasProtectedSiteRules: Bool
    ) -> BrowserProtectionProjection {
        if permissionHealth.screenRecording != .granted {
            let revoked = permissionHealth.screenRecording == .revoked
            return blocked(
                resolution: .unavailable(.screenRecordingPermissionUnavailable),
                issue: revoked
                    ? .screenRecordingPermissionRevoked
                    : .screenRecordingPermissionDenied,
                reason: revoked
                    ? "Recording paused because Screen Recording permission was revoked."
                    : "Recording paused because Screen Recording permission is required.",
                gap: .permissionLost
            )
        }
        if permissionHealth.accessibility != .granted {
            let revoked = permissionHealth.accessibility == .revoked
            return blocked(
                resolution: .unavailable(.accessibilityPermissionUnavailable),
                issue: revoked
                    ? .accessibilityPermissionRevoked
                    : .accessibilityPermissionDenied,
                reason: revoked
                    ? "Browser capture paused to protect site exclusions because Accessibility permission was revoked."
                    : "Browser capture paused to protect site exclusions because Accessibility permission is required.",
                gap: .permissionLost
            )
        }
        guard registry.adapter(for: bundleIdentifier) != nil else {
            return unavailable(.unsupportedBrowser)
        }
        guard let applicationVersion = normalizedVersion(applicationVersion) else {
            return unavailable(.browserVersionUnavailable)
        }
        if let previousVersion = observedVersions[bundleIdentifier],
            previousVersion != applicationVersion
        {
            observedVersions[bundleIdentifier] = applicationVersion
            return blocked(
                resolution: .unavailable(.browserVersionChanged),
                issue: .browserVersionChanged,
                reason:
                    "Browser capture paused to protect site exclusions because the browser version changed and context must be revalidated.",
                gap: .filterFailed
            )
        }
        observedVersions[bundleIdentifier] = applicationVersion

        switch rawResolution {
        case .approved:
            return BrowserProtectionProjection(
                browserContext: rawResolution,
                issue: nil,
                userVisibleReason: nil,
                timelineGapReason: nil
            )
        case .privateContext:
            if privateBrowserHandling == .exclude {
                return blocked(
                    resolution: rawResolution,
                    issue: .privateContextExcluded,
                    reason: "Private browser windows are excluded by your privacy policy.",
                    gap: .excluded
                )
            }
            if hasProtectedSiteRules {
                return blocked(
                    resolution: .unavailable(.privateStateUnavailable),
                    issue: .protectedURLContextUnavailable,
                    reason:
                        "Browser capture paused to protect site exclusions because private URL context is unavailable.",
                    gap: .filterFailed
                )
            }
            return BrowserProtectionProjection(
                browserContext: rawResolution,
                issue: nil,
                userVisibleReason: nil,
                timelineGapReason: nil
            )
        case .unavailable(let reason):
            return unavailable(reason)
        }
    }

    private func unavailable(
        _ reason: BrowserContextUnavailableReason
    ) -> BrowserProtectionProjection {
        blocked(
            resolution: .unavailable(reason),
            issue: .protectedURLContextUnavailable,
            reason:
                "Browser capture paused to protect site exclusions: \(Self.visibleLabel(for: reason)).",
            gap: .filterFailed
        )
    }

    private func blocked(
        resolution: BrowserContextResolution,
        issue: BrowserProtectionIssue,
        reason: String,
        gap: RecordingGapReason
    ) -> BrowserProtectionProjection {
        BrowserProtectionProjection(
            browserContext: resolution,
            issue: issue,
            userVisibleReason: reason,
            timelineGapReason: gap
        )
    }

    private func normalizedVersion(_ version: String?) -> String? {
        guard let version else { return nil }
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128,
            normalized.unicodeScalars.allSatisfy({ scalar in
                scalar.properties.isAlphabetic
                    || scalar.properties.numericType != nil
                    || ".-_() ".unicodeScalars.contains(scalar)
            })
        else {
            return nil
        }
        return normalized
    }

    private static func visibleLabel(
        for reason: BrowserContextUnavailableReason
    ) -> String {
        switch reason {
        case .unsupportedBrowser:
            "this browser is not supported"
        case .targetWindowMismatch:
            "the protected browser window changed"
        case .ambiguousAddressField:
            "the browser exposed more than one possible address"
        case .privateStateUnavailable:
            "private-window state is unavailable"
        case .urlUnavailable:
            "the protected URL is unavailable"
        case .unsupportedURL:
            "the current URL cannot be safely represented"
        case .screenRecordingPermissionUnavailable:
            "Screen Recording permission is unavailable"
        case .accessibilityPermissionUnavailable:
            "Accessibility permission is unavailable"
        case .browserVersionUnavailable:
            "the browser version is unavailable"
        case .browserVersionChanged:
            "the browser version changed and context must be revalidated"
        }
    }
}
