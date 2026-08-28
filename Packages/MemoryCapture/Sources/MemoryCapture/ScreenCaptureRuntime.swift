import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

public enum ScreenRecordingPermission: String, Codable, Equatable, Sendable {
    case granted
    case denied
}

public protocol ScreenRecordingPermissionProbing: Sendable {
    func currentPermission() async -> ScreenRecordingPermission
}

public struct ScreenCaptureKitPermissionProbe: ScreenRecordingPermissionProbing {
    public init() {}

    public func currentPermission() async -> ScreenRecordingPermission {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }
}

public enum CaptureSurfaceKind: String, Codable, Equatable, Sendable {
    case foregroundWindow
}

private struct UnsafeSendableSCWindow: @unchecked Sendable {
    let value: SCWindow
}

public struct ForegroundWindowCaptureTarget: @unchecked Sendable, Equatable {
    public let windowID: UInt32
    public let processID: Int32
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let title: String?
    public let bounds: PointRect
    public let isOnScreen: Bool
    public let isNormalContent: Bool
    public let intersectsMainDisplay: Bool
    public let isEligibleForegroundWindow: Bool
    public let surfaceKind: CaptureSurfaceKind
    private let platformWindow: UnsafeSendableSCWindow?

    private init(
        windowID: UInt32,
        processID: Int32,
        displayID: UInt32,
        width: Int,
        height: Int,
        title: String?,
        bounds: PointRect,
        isOnScreen: Bool,
        isNormalContent: Bool,
        intersectsMainDisplay: Bool,
        isEligibleForegroundWindow: Bool,
        platformWindow: SCWindow?
    ) {
        self.windowID = windowID
        self.processID = processID
        self.displayID = displayID
        self.width = width
        self.height = height
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.isNormalContent = isNormalContent
        self.intersectsMainDisplay = intersectsMainDisplay
        self.isEligibleForegroundWindow = isEligibleForegroundWindow
        surfaceKind = .foregroundWindow
        self.platformWindow = platformWindow.map(UnsafeSendableSCWindow.init)
    }

    public static func fixture(
        windowID: UInt32,
        processID: Int32,
        displayID: UInt32,
        width: Int,
        height: Int,
        title: String? = nil,
        bounds: PointRect? = nil,
        isOnScreen: Bool? = nil,
        isNormalContent: Bool? = nil,
        intersectsMainDisplay: Bool? = nil,
        isEligibleForegroundWindow: Bool = true
    ) -> Self {
        Self(
            windowID: windowID,
            processID: processID,
            displayID: displayID,
            width: width,
            height: height,
            title: title,
            bounds: bounds ?? PointRect(x: 0, y: 0, width: Double(width), height: Double(height)),
            isOnScreen: isOnScreen ?? isEligibleForegroundWindow,
            isNormalContent: isNormalContent ?? isEligibleForegroundWindow,
            intersectsMainDisplay: intersectsMainDisplay ?? isEligibleForegroundWindow,
            isEligibleForegroundWindow: isEligibleForegroundWindow,
            platformWindow: nil
        )
    }

    fileprivate static func screenCaptureKit(
        window: SCWindow,
        displayID: UInt32,
        intersectsMainDisplay: Bool,
        isEligibleForegroundWindow: Bool
    ) -> Self {
        Self(
            windowID: window.windowID,
            processID: window.owningApplication?.processID ?? -1,
            displayID: displayID,
            width: Int(window.frame.width),
            height: Int(window.frame.height),
            title: window.title,
            bounds: PointRect(
                x: window.frame.origin.x,
                y: window.frame.origin.y,
                width: window.frame.width,
                height: window.frame.height
            ),
            isOnScreen: window.isOnScreen,
            isNormalContent: window.windowLayer == 0,
            intersectsMainDisplay: intersectsMainDisplay,
            isEligibleForegroundWindow: isEligibleForegroundWindow,
            platformWindow: window
        )
    }

    fileprivate var screenCaptureKitWindow: SCWindow? {
        platformWindow?.value
    }

    public var descriptor: ShareableWindowDescriptor {
        ShareableWindowDescriptor(
            windowID: windowID,
            processID: processID,
            bounds: bounds,
            title: title,
            isOnScreen: isOnScreen,
            isNormalContent: isNormalContent,
            intersectsMainDisplay: intersectsMainDisplay
        )
    }

    public static func fixture(_ descriptor: ShareableWindowDescriptor) -> Self {
        fixture(
            windowID: descriptor.windowID,
            processID: descriptor.processID,
            displayID: descriptor.intersectsMainDisplay ? 1 : 0,
            width: Int(descriptor.bounds.width),
            height: Int(descriptor.bounds.height),
            title: descriptor.title,
            bounds: descriptor.bounds,
            isOnScreen: descriptor.isOnScreen,
            isNormalContent: descriptor.isNormalContent,
            intersectsMainDisplay: descriptor.intersectsMainDisplay,
            isEligibleForegroundWindow: descriptor.isOnScreen
                && descriptor.isNormalContent
                && descriptor.intersectsMainDisplay
                && descriptor.bounds.width > 0
                && descriptor.bounds.height > 0
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID
            && lhs.processID == rhs.processID
            && lhs.displayID == rhs.displayID
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.title == rhs.title
            && lhs.bounds == rhs.bounds
            && lhs.isOnScreen == rhs.isOnScreen
            && lhs.isNormalContent == rhs.isNormalContent
            && lhs.intersectsMainDisplay == rhs.intersectsMainDisplay
            && lhs.isEligibleForegroundWindow == rhs.isEligibleForegroundWindow
            && lhs.surfaceKind == rhs.surfaceKind
    }
}

public enum ShareableWindowRefreshStatus: String, Codable, Equatable, Sendable {
    case available
    case timedOut
    case suppressedDuringCooldown
    case permissionDenied
    case failed
}

public struct ShareableWindowRefreshResult: @unchecked Sendable, Equatable {
    public let status: ShareableWindowRefreshStatus
    public let targets: [ForegroundWindowCaptureTarget]

    public init(
        status: ShareableWindowRefreshStatus,
        targets: [ForegroundWindowCaptureTarget]
    ) {
        self.status = status
        self.targets = targets
    }
}

public protocol ShareableWindowRefreshing: Sendable {
    func refresh() async -> ShareableWindowRefreshResult
}

public struct ShareableContentRefreshLeaseToken: Equatable, Sendable {
    fileprivate let id: UUID
}

public struct ShareableContentRefreshLeaseGate: Sendable {
    private struct ActiveLease: Sendable {
        let token: ShareableContentRefreshLeaseToken
        let startedNanoseconds: UInt64
        var timedOut: Bool
    }

    private var active: ActiveLease?

    public init() {}

    public mutating func begin(
        nowNanoseconds: UInt64,
        cooldownNanoseconds: UInt64
    ) -> ShareableContentRefreshLeaseToken? {
        if let active,
           nowNanoseconds >= active.startedNanoseconds,
           nowNanoseconds - active.startedNanoseconds < cooldownNanoseconds
        {
            return nil
        }
        let token = ShareableContentRefreshLeaseToken(id: UUID())
        active = ActiveLease(
            token: token,
            startedNanoseconds: nowNanoseconds,
            timedOut: false
        )
        return token
    }

    public mutating func markTimedOut(_ token: ShareableContentRefreshLeaseToken) {
        guard active?.token == token else {
            return
        }
        active?.timedOut = true
    }

    public mutating func acceptCompletion(_ token: ShareableContentRefreshLeaseToken) -> Bool {
        guard let active, active.token == token, !active.timedOut else {
            return false
        }
        self.active = nil
        return true
    }
}

public final class ScreenCaptureKitShareableWindowRefresher: ShareableWindowRefreshing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var leaseGate = ShareableContentRefreshLeaseGate()
    private let timeoutNanoseconds: UInt64
    private let cooldownNanoseconds: UInt64

    public init(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        cooldownNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.cooldownNanoseconds = cooldownNanoseconds
    }

    public func refresh() async -> ShareableWindowRefreshResult {
        guard CGPreflightScreenCaptureAccess() else {
            return ShareableWindowRefreshResult(status: .permissionDenied, targets: [])
        }
        let token = lock.withLock {
            leaseGate.begin(
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                cooldownNanoseconds: cooldownNanoseconds
            )
        }
        guard let token else {
            return ShareableWindowRefreshResult(status: .suppressedDuringCooldown, targets: [])
        }

        return await withCheckedContinuation { continuation in
            let box = ShareableWindowRefreshContinuationBox(continuation: continuation)
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ) { [weak self] content, error in
                guard let self else {
                    box.resolve(ShareableWindowRefreshResult(status: .failed, targets: []))
                    return
                }
                let accepted = lock.withLock {
                    leaseGate.acceptCompletion(token)
                }
                guard accepted else {
                    return
                }
                guard error == nil, let content else {
                    box.resolve(ShareableWindowRefreshResult(status: .failed, targets: []))
                    return
                }
                box.resolve(Self.result(from: content))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))
            ) { [weak self] in
                self?.lock.withLock {
                    self?.leaseGate.markTimedOut(token)
                }
                box.resolve(ShareableWindowRefreshResult(status: .timedOut, targets: []))
            }
        }
    }

    private static func result(from content: SCShareableContent) -> ShareableWindowRefreshResult {
        let mainDisplayID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainDisplayID)
        let targets = content.windows.map { window in
            let intersectsMain = window.frame.intersects(mainBounds)
            let eligible = window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 0
                && window.frame.height > 0
                && intersectsMain
            return ForegroundWindowCaptureTarget.screenCaptureKit(
                window: window,
                displayID: intersectsMain ? mainDisplayID : 0,
                intersectsMainDisplay: intersectsMain,
                isEligibleForegroundWindow: eligible
            )
        }
        return ShareableWindowRefreshResult(status: .available, targets: targets)
    }
}

private final class ShareableWindowRefreshContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShareableWindowRefreshResult, Never>?

    init(continuation: CheckedContinuation<ShareableWindowRefreshResult, Never>) {
        self.continuation = continuation
    }

    func resolve(_ result: ShareableWindowRefreshResult) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

public enum ForegroundWindowPixelBufferError: Error, Equatable, Sendable {
    case alreadyConsumed
}

public final class ForegroundWindowPixelBuffer: @unchecked Sendable {
    private enum State {
        case ready(CVPixelBuffer)
        case inUse
        case released
    }

    public let targetWindowID: UInt32
    public let capturedNanoseconds: UInt64
    public let surfaceKind: CaptureSurfaceKind = .foregroundWindow
    private let lock = NSLock()
    private var state: State

    public init(
        pixelBuffer: CVPixelBuffer,
        targetWindowID: UInt32,
        capturedNanoseconds: UInt64
    ) {
        self.targetWindowID = targetWindowID
        self.capturedNanoseconds = capturedNanoseconds
        state = .ready(pixelBuffer)
    }

    public var isReleased: Bool {
        lock.withLock {
            if case .released = state {
                return true
            }
            return false
        }
    }

    public func withPixelBufferForMediaCommit<T>(
        _ commit: (CVPixelBuffer) throws -> T
    ) throws -> T {
        let buffer = try lock.withLock { () throws -> CVPixelBuffer in
            guard case let .ready(buffer) = state else {
                throw ForegroundWindowPixelBufferError.alreadyConsumed
            }
            state = .inUse
            return buffer
        }
        defer {
            lock.withLock {
                state = .released
            }
        }
        return try commit(buffer)
    }

    public func discardWithoutPersistence() {
        lock.withLock {
            state = .released
        }
    }
}

public protocol ForegroundWindowStreamDriving: Sendable {
    func start(
        target: ForegroundWindowCaptureTarget,
        frameHandler: @escaping @Sendable (ForegroundWindowPixelBuffer) -> Void
    ) async throws
    func stop() async
}

public enum ForegroundWindowStreamError: Error, Equatable, Sendable {
    case missingScreenCaptureKitWindow
    case ineligibleTarget
}

public final class ScreenCaptureKitForegroundWindowStreamDriver: ForegroundWindowStreamDriving,
    @unchecked Sendable
{
    private struct RunningStream {
        let stream: SCStream
        let output: ForegroundWindowStreamOutput
    }

    private let lock = NSLock()
    private var running: RunningStream?
    private let sampleQueue = DispatchQueue(
        label: "com.justinhou.deepshelves.foreground-window-stream"
    )

    public init() {}

    public func start(
        target: ForegroundWindowCaptureTarget,
        frameHandler: @escaping @Sendable (ForegroundWindowPixelBuffer) -> Void
    ) async throws {
        guard target.isEligibleForegroundWindow else {
            throw ForegroundWindowStreamError.ineligibleTarget
        }
        guard let window = target.screenCaptureKitWindow else {
            throw ForegroundWindowStreamError.missingScreenCaptureKitWindow
        }
        await stop()

        let encodedSize = CaptureGeometry.encodedSize(
            for: PointRect(
                x: 0,
                y: 0,
                width: Double(target.width),
                height: Double(target.height)
            )
        )
        let configuration = SCStreamConfiguration()
        configuration.width = encodedSize.width
        configuration.height = encodedSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = CaptureConstants.streamQueueDepth
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.shouldBeOpaque = true

        let output = ForegroundWindowStreamOutput(
            targetWindowID: target.windowID,
            frameHandler: frameHandler
        )
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration,
            delegate: output
        )
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
            lock.withLock {
                running = RunningStream(stream: stream, output: output)
            }
        } catch {
            try? stream.removeStreamOutput(output, type: .screen)
            throw error
        }
    }

    public func stop() async {
        let prior = lock.withLock {
            defer { running = nil }
            return running
        }
        guard let prior else {
            return
        }
        try? await prior.stream.stopCapture()
        try? prior.stream.removeStreamOutput(prior.output, type: .screen)
    }
}

private final class ForegroundWindowStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let targetWindowID: UInt32
    let frameHandler: @Sendable (ForegroundWindowPixelBuffer) -> Void

    init(
        targetWindowID: UInt32,
        frameHandler: @escaping @Sendable (ForegroundWindowPixelBuffer) -> Void
    ) {
        self.targetWindowID = targetWindowID
        self.frameHandler = frameHandler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              Self.isComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }
        frameHandler(
            ForegroundWindowPixelBuffer(
                pixelBuffer: pixelBuffer,
                targetWindowID: targetWindowID,
                capturedNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        )
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {}

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        else {
            return false
        }
        return status == .complete || status == .started
    }
}

public enum ScreenCaptureLifecycleState: Equatable, Sendable {
    case stoppedNoEligibleTarget
    case permissionDenied
    case refreshUnavailable(ShareableWindowRefreshStatus)
    case running(windowID: UInt32, displayID: UInt32)
    case failed(String)
}

public actor ScreenCaptureLifecycleController {
    public private(set) var state: ScreenCaptureLifecycleState = .stoppedNoEligibleTarget

    private let permissionProbe: any ScreenRecordingPermissionProbing
    private let refresher: any ShareableWindowRefreshing
    private let streamDriver: any ForegroundWindowStreamDriving
    private let frameHandler: @Sendable (ForegroundWindowPixelBuffer) -> Void
    private var activeWindowID: UInt32?

    public init(
        permissionProbe: any ScreenRecordingPermissionProbing,
        refresher: any ShareableWindowRefreshing,
        streamDriver: any ForegroundWindowStreamDriving,
        frameHandler: @escaping @Sendable (ForegroundWindowPixelBuffer) -> Void = {
            $0.discardWithoutPersistence()
        }
    ) {
        self.permissionProbe = permissionProbe
        self.refresher = refresher
        self.streamDriver = streamDriver
        self.frameHandler = frameHandler
    }

    public func reconcile(targetWindowID: UInt32?) async {
        guard await permissionProbe.currentPermission() == .granted else {
            await stopActiveStream()
            state = .permissionDenied
            return
        }
        guard let targetWindowID else {
            await stopActiveStream()
            state = .stoppedNoEligibleTarget
            return
        }

        let refresh = await refresher.refresh()
        guard refresh.status == .available else {
            await stopActiveStream()
            state = .refreshUnavailable(refresh.status)
            return
        }
        guard let target = refresh.targets.first(where: {
            $0.windowID == targetWindowID && $0.isEligibleForegroundWindow
        }) else {
            await stopActiveStream()
            state = .stoppedNoEligibleTarget
            return
        }
        if activeWindowID == target.windowID,
           state == .running(windowID: target.windowID, displayID: target.displayID)
        {
            return
        }
        await stopActiveStream()
        do {
            try await streamDriver.start(target: target, frameHandler: frameHandler)
            activeWindowID = target.windowID
            state = .running(windowID: target.windowID, displayID: target.displayID)
        } catch {
            activeWindowID = nil
            state = .failed(String(describing: error))
        }
    }

    public func restartAfterDisplayChange(targetWindowID: UInt32?) async {
        await stopActiveStream()
        state = .stoppedNoEligibleTarget
        await reconcile(targetWindowID: targetWindowID)
    }

    public func stop() async {
        await stopActiveStream()
        state = .stoppedNoEligibleTarget
    }

    private func stopActiveStream() async {
        guard activeWindowID != nil else {
            return
        }
        await streamDriver.stop()
        activeWindowID = nil
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
