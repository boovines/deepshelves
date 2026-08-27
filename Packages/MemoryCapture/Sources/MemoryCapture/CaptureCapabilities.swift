import ApplicationServices
import CoreGraphics
import Foundation

public enum CaptureCapability: String, Codable, Equatable, Sendable {
    case screenRecording
    case accessibility
}

public struct CaptureCapabilityStatus: Codable, Equatable, Sendable {
    public let screenRecording: Bool
    public let accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    public var missing: [CaptureCapability] {
        var capabilities: [CaptureCapability] = []
        if !screenRecording {
            capabilities.append(.screenRecording)
        }
        if !accessibility {
            capabilities.append(.accessibility)
        }
        return capabilities
    }

    public var isReady: Bool {
        missing.isEmpty
    }
}

public enum CaptureCapabilities: Sendable {
    public static func current() -> CaptureCapabilityStatus {
        CaptureCapabilityStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    @discardableResult
    public static func requestFromUser() -> CaptureCapabilityStatus {
        let screenRecording = CGRequestScreenCaptureAccess()
        let accessibility = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        return CaptureCapabilityStatus(
            screenRecording: screenRecording,
            accessibility: accessibility
        )
    }
}
