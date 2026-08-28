import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

public struct CaptureSpikeReport: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let targetWindowID: UInt32
    public let captureEpochID: UUID
    public let encodedWidth: Int
    public let encodedHeight: Int
    public let framesReceived: Int
    public let framesAccepted: Int
    public let framesIndexed: Int
    public let staleOrPolicyFramesRejected: Int
    public let backpressureDrops: Int
    public let contaminationFrames: Int
    public let writerErrors: [String]
    public let diagnostics: [String]
    public let mediaPath: String
    public let mediaPaths: [String]
    public let eligibleFocusTransitions: Int
    public let correctWithinOneSecondTransitions: Int
    public let unresolvedOrExcludedTransitions: Int
    public let filterUpdateLatenciesMilliseconds: [Double]
    public let chunks: [CaptureChunkScopeRecord]
    public let sleepTransitions: Int
    public let wakeTransitions: Int
}

public struct CaptureChunkScopeRecord: Codable, Equatable, Sendable {
    public let path: String
    public let epochID: UUID
    public let targetWindowID: UInt32
    public let width: Int
    public let height: Int
}

public enum CaptureSpikeError: Error, CustomStringConvertible, Sendable {
    case capabilitiesMissing([CaptureCapability])
    case focusedWindowUnavailable
    case windowResolution(CaptureGapReason)
    case resolvedWindowDisappeared
    case missingImageBuffer

    public var description: String {
        switch self {
        case .capabilitiesMissing(let capabilities):
            "Missing capabilities: \(capabilities.map(\.rawValue).joined(separator: ", "))"
        case .focusedWindowUnavailable:
            "No public-API focused window was available."
        case .windowResolution(let reason):
            "Focused window resolution failed closed: \(reason.rawValue)."
        case .resolvedWindowDisappeared:
            "The resolved ScreenCaptureKit window disappeared before capture."
        case .missingImageBuffer:
            "ScreenCaptureKit delivered a frame without an image buffer."
        }
    }
}

public final class CaptureSpikeRunner: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private let stateLock = NSLock()
    private let sampleQueue = DispatchQueue(
        label: "com.justinhou.deepshelves.capture-spike.samples")
    private let shareableContentProvider = BoundedShareableContentProvider()
    private let frameEncoder: any HEICFrameEncoding

    private var epoch: WindowCaptureEpoch?
    private var writer: HEICKeyframeWriter?
    private var acceptanceGate = FrameAcceptanceGate()
    private var prefilterEpochID: UUID?
    private var prefilterSignature: UInt64?
    private var prefilterLastForwardedNanoseconds: UInt64?
    private var lastActivityNanoseconds: UInt64 = 0
    private var framesReceived = 0
    private var framesAccepted = 0
    private var framesIndexed = 0
    private var staleOrPolicyFramesRejected = 0
    private var backpressureDrops = 0
    private var contaminationFrames = 0
    private var writerErrors: [String] = []
    private var diagnostics: [String] = []
    private var mediaPaths: [String] = []
    private var eligibleFocusTransitions = 0
    private var correctWithinOneSecondTransitions = 0
    private var unresolvedOrExcludedTransitions = 0
    private var filterUpdateLatenciesMilliseconds: [Double] = []
    private var chunkRecords: [CaptureChunkScopeRecord] = []
    private var lifecycleSuspended = false
    private var sleepTransitions = 0
    private var wakeTransitions = 0

    public init(frameEncoder: any HEICFrameEncoding = QuarantinedHEICFrameEncoder()) {
        self.frameEncoder = frameEncoder
        super.init()
    }

    public static func production() throws -> CaptureSpikeRunner {
        CaptureSpikeRunner(frameEncoder: try SoftwareHEICFrameEncoder())
    }

    public func run(outputURL: URL, duration: Duration) async throws -> CaptureSpikeReport {
        let capabilityStatus = CaptureCapabilities.current()
        guard capabilityStatus.isReady else {
            throw CaptureSpikeError.capabilitiesMissing(capabilityStatus.missing)
        }
        let startedAt = Date()
        let initialTarget = try await resolveCurrentTarget().get()
        let initialFilter = SCContentFilter(desktopIndependentWindow: initialTarget.scWindow)
        let initialConfiguration = streamConfiguration(for: initialTarget.dimensions)
        let stream = SCStream(
            filter: initialFilter, configuration: initialConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        defer {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
        try await stream.updateContentFilter(initialFilter)
        try await stream.updateConfiguration(initialConfiguration)
        let initialEpoch = try installEpoch(
            target: initialTarget,
            outputURL: outputURL,
            transitionStartedNanoseconds: DispatchTime.now().uptimeNanoseconds,
            countsAsTransition: false
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        let writerRolloverInterval = Duration.nanoseconds(
            CaptureConstants.writerRolloverIntervalNanoseconds
        )
        var nextChunkRollover = clock.now.advanced(by: writerRolloverInterval)
        var focusSignature: String? = initialTarget.focused.signature
        var chunkIndex = 1
        var streamIsRunning = true
        while clock.now < deadline {
            try await Task.sleep(
                for: .nanoseconds(CaptureConstants.focusPollIntervalNanoseconds)
            )
            let isSuspended = stateLock.withLock { lifecycleSuspended }
            if isSuspended {
                if streamIsRunning {
                    try await revokeAndFinishCurrentWriter()
                    try await stream.stopCapture()
                    streamIsRunning = false
                    focusSignature = nil
                    stateLock.withLock {
                        sleepTransitions += 1
                    }
                }
                continue
            }
            if !streamIsRunning {
                try await stream.startCapture()
                streamIsRunning = true
                focusSignature = nil
                stateLock.withLock {
                    wakeTransitions += 1
                }
            }
            if clock.now >= nextChunkRollover,
                stateLock.withLock({ epoch != nil })
            {
                let chunkURL = transitionOutputURL(base: outputURL, index: chunkIndex)
                try await rolloverCurrentWriter(outputURL: chunkURL)
                chunkIndex += 1
                nextChunkRollover = clock.now.advanced(by: writerRolloverInterval)
            }
            let nextFocused = FocusedWindowReader.current()
            let nextSignature = nextFocused?.signature
            guard nextSignature != focusSignature else {
                continue
            }
            focusSignature = nextSignature
            let transitionStarted = DispatchTime.now().uptimeNanoseconds
            try await revokeAndFinishCurrentWriter()
            switch try await resolveCurrentTarget() {
            case .approved(let target):
                let configuration = streamConfiguration(for: target.dimensions)
                try await stream.updateContentFilter(
                    SCContentFilter(desktopIndependentWindow: target.scWindow)
                )
                try await stream.updateConfiguration(configuration)
                let chunkURL = transitionOutputURL(base: outputURL, index: chunkIndex)
                _ = try installEpoch(
                    target: target,
                    outputURL: chunkURL,
                    transitionStartedNanoseconds: transitionStarted,
                    countsAsTransition: true
                )
                chunkIndex += 1
                nextChunkRollover = clock.now.advanced(by: writerRolloverInterval)
                stateLock.withLock {
                    eligibleFocusTransitions += 1
                }
            case .gap(let reason):
                stateLock.withLock {
                    unresolvedOrExcludedTransitions += 1
                    if diagnostics.count < 32 {
                        diagnostics.append("metadataOnlyGap=\(reason.rawValue)")
                    }
                }
            }
        }

        try await revokeAndFinishCurrentWriter()
        if streamIsRunning {
            try await stream.stopCapture()
        }

        let endedAt = Date()
        return stateLock.withLock {
            CaptureSpikeReport(
                startedAt: startedAt,
                endedAt: endedAt,
                targetWindowID: initialTarget.approved.windowID,
                captureEpochID: initialEpoch.id,
                encodedWidth: initialTarget.dimensions.width,
                encodedHeight: initialTarget.dimensions.height,
                framesReceived: framesReceived,
                framesAccepted: framesAccepted,
                framesIndexed: framesIndexed,
                staleOrPolicyFramesRejected: staleOrPolicyFramesRejected,
                backpressureDrops: backpressureDrops,
                contaminationFrames: contaminationFrames,
                writerErrors: writerErrors,
                diagnostics: diagnostics,
                mediaPath: outputURL.path,
                mediaPaths: mediaPaths.filter { FileManager.default.fileExists(atPath: $0) },
                eligibleFocusTransitions: eligibleFocusTransitions,
                correctWithinOneSecondTransitions: correctWithinOneSecondTransitions,
                unresolvedOrExcludedTransitions: unresolvedOrExcludedTransitions,
                filterUpdateLatenciesMilliseconds: filterUpdateLatenciesMilliseconds,
                chunks: chunkRecords.filter { FileManager.default.fileExists(atPath: $0.path) },
                sleepTransitions: sleepTransitions,
                wakeTransitions: wakeTransitions
            )
        }
    }

    private func resolveCurrentTarget() async throws -> TargetResolution {
        guard let focused = FocusedWindowReader.current() else {
            return .gap(.noWindow)
        }
        guard let shareableContent = await shareableContentProvider.content() else {
            return .gap(.unresolvedWindow)
        }
        let mainDisplayFrame = NSScreen.main?.frame ?? .zero
        let descriptors = shareableContent.windows.map {
            ShareableWindowDescriptor(
                windowID: $0.windowID,
                processID: $0.owningApplication?.processID ?? -1,
                bounds: PointRect($0.frame),
                title: $0.title,
                isOnScreen: $0.isOnScreen,
                isNormalContent: $0.windowLayer == 0
                    && !($0.title?.contains("PROHIBITED") ?? false),
                intersectsMainDisplay: $0.frame.intersects(mainDisplayFrame)
            )
        }
        switch WindowResolver.resolve(focused: focused, candidates: descriptors) {
        case .approved(let approved):
            guard
                let scWindow = shareableContent.windows.first(where: {
                    $0.windowID == approved.windowID
                })
            else {
                throw CaptureSpikeError.resolvedWindowDisappeared
            }
            return .approved(
                ResolvedTarget(
                    focused: focused,
                    approved: approved,
                    scWindow: scWindow,
                    dimensions: CaptureGeometry.encodedSize(for: approved.bounds)
                )
            )
        case .gap(let reason):
            return .gap(reason)
        }
    }

    private func installEpoch(
        target: ResolvedTarget,
        outputURL: URL,
        transitionStartedNanoseconds: UInt64,
        countsAsTransition: Bool
    ) throws -> WindowCaptureEpoch {
        let appliedAt = DispatchTime.now().uptimeNanoseconds
        let epoch = WindowCaptureEpoch(
            id: UUID(),
            targetWindowID: target.approved.windowID,
            processID: target.approved.processID,
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            approvedBounds: target.approved.bounds,
            policyDecisionID: UUID(),
            encodedSize: target.dimensions,
            filterAppliedNanoseconds: appliedAt
        )
        let mediaWriter = try HEICKeyframeWriter(
            outputDirectoryURL: outputURL,
            scope: MediaChunkScope(
                epochID: epoch.id,
                targetWindowID: epoch.targetWindowID,
                dimensions: epoch.encodedSize,
                startedNanoseconds: appliedAt
            ),
            encoder: frameEncoder
        )
        let latencyMilliseconds = Double(appliedAt - transitionStartedNanoseconds) / 1_000_000
        stateLock.withLock {
            writer = mediaWriter
            self.epoch = epoch
            lastActivityNanoseconds = appliedAt
            mediaPaths.append(outputURL.path)
            chunkRecords.append(
                CaptureChunkScopeRecord(
                    path: outputURL.path,
                    epochID: epoch.id,
                    targetWindowID: epoch.targetWindowID,
                    width: epoch.encodedSize.width,
                    height: epoch.encodedSize.height
                )
            )
            if countsAsTransition {
                filterUpdateLatenciesMilliseconds.append(latencyMilliseconds)
                if latencyMilliseconds <= 1_000 {
                    correctWithinOneSecondTransitions += 1
                }
            }
        }
        return epoch
    }

    private func revokeAndFinishCurrentWriter() async throws {
        let priorWriter = stateLock.withLock { () -> HEICKeyframeWriter? in
            epoch = nil
            let priorWriter = writer
            writer = nil
            return priorWriter
        }
        if let priorWriter {
            _ = try priorWriter.finish()
        }
    }

    private func rolloverCurrentWriter(outputURL: URL) async throws {
        let prior = stateLock.withLock { () -> (HEICKeyframeWriter?, WindowCaptureEpoch?) in
            let prior = (writer, epoch)
            epoch = nil
            writer = nil
            return prior
        }
        guard let priorWriter = prior.0, let continuingEpoch = prior.1 else {
            return
        }
        _ = try priorWriter.finish()
        let nextWriter = try HEICKeyframeWriter(
            outputDirectoryURL: outputURL,
            scope: MediaChunkScope(
                epochID: continuingEpoch.id,
                targetWindowID: continuingEpoch.targetWindowID,
                dimensions: continuingEpoch.encodedSize,
                startedNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            encoder: frameEncoder
        )
        stateLock.withLock {
            writer = nextWriter
            epoch = continuingEpoch
            mediaPaths.append(outputURL.path)
            chunkRecords.append(
                CaptureChunkScopeRecord(
                    path: outputURL.path,
                    epochID: continuingEpoch.id,
                    targetWindowID: continuingEpoch.targetWindowID,
                    width: continuingEpoch.encodedSize.width,
                    height: continuingEpoch.encodedSize.height
                )
            )
        }
    }

    private func streamConfiguration(for dimensions: PixelSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.queueDepth = CaptureConstants.streamQueueDepth
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.shouldBeOpaque = true
        return configuration
    }

    private func transitionOutputURL(base: URL, index: Int) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(
            "\(base.lastPathComponent)-\(String(format: "%04d", index))",
            isDirectory: true
        )
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid, frameIsComplete(sampleBuffer) else {
            return
        }

        stateLock.withLock {
            framesReceived += 1
            guard let epoch, let writer else {
                staleOrPolicyFramesRejected += 1
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard let imageBuffer = sampleBuffer.imageBuffer else {
                writerErrors.append(CaptureSpikeError.missingImageBuffer.description)
                return
            }
            let signature = LumaFrameInspector.signature(of: imageBuffer)
            guard
                shouldRunPreAppendChecks(
                    epochID: epoch.id,
                    signature: signature,
                    now: now
                )
            else {
                return
            }
            let focused = FocusedWindowReader.current()
            let focusMatches =
                focused.map {
                    WindowResolver.resolve(
                        focused: $0,
                        candidates: [
                            ShareableWindowDescriptor(
                                windowID: epoch.targetWindowID,
                                processID: epoch.processID,
                                bounds: epoch.approvedBounds,
                                title: $0.title,
                                isOnScreen: true,
                                isNormalContent: true,
                                intersectsMainDisplay: true
                            )
                        ]
                    )
                        == .approved(
                            ShareableWindowDescriptor(
                                windowID: epoch.targetWindowID,
                                processID: epoch.processID,
                                bounds: epoch.approvedBounds,
                                title: $0.title,
                                isOnScreen: true,
                                isNormalContent: true,
                                intersectsMainDisplay: true
                            )
                        )
                } ?? false
            let candidate = FrameCandidate(
                epochID: epoch.id,
                targetWindowID: epoch.targetWindowID,
                focusedWindowID: focusMatches ? epoch.targetWindowID : nil,
                dimensions: sampleBuffer.pixelDimensions,
                deliveredNanoseconds: now,
                policyApproved: focusMatches,
                filterGeneration: epoch.filterGeneration,
                policyDecisionID: epoch.policyDecisionID
            )
            let admission = FrameAdmission.evaluate(candidate, against: epoch)
            guard admission == .accepted else {
                staleOrPolicyFramesRejected += 1
                if diagnostics.count < 8 {
                    let focusedDescription =
                        focused.map {
                            "pid=\($0.processID) bounds=\($0.bounds) title=\($0.title ?? "")"
                        } ?? "none"
                    diagnostics.append(
                        "rejected=\(admission) current=\(focusedDescription) approvedPid=\(epoch.processID) approvedBounds=\(epoch.approvedBounds) sample=\(candidate.dimensions) expected=\(epoch.encodedSize)"
                    )
                }
                return
            }
            switch acceptanceGate.evaluate(
                epochID: epoch.id,
                timestampNanoseconds: now,
                signature: signature,
                lastActivityNanoseconds: lastActivityNanoseconds
            ) {
            case .accepted(let index, _):
                do {
                    _ = try writer.append(
                        imageBuffer,
                        frameID: UUID(),
                        captureEpochID: epoch.id,
                        targetWindowID: epoch.targetWindowID,
                        sourcePresentationTimeMilliseconds: Int64(
                            (CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000)
                                .rounded()
                        )
                    )
                    framesAccepted += 1
                    if index {
                        framesIndexed += 1
                    }
                    if LumaFrameInspector.containsSentinelContamination(imageBuffer) {
                        contaminationFrames += 1
                    }
                } catch {
                    writerErrors.append(String(describing: error))
                }
            case .rejected:
                break
            }
        }
    }

    private func shouldRunPreAppendChecks(
        epochID: UUID,
        signature: UInt64,
        now: UInt64
    ) -> Bool {
        if prefilterEpochID != epochID {
            prefilterEpochID = epochID
            prefilterSignature = signature
            prefilterLastForwardedNanoseconds = now
            return true
        }
        if prefilterSignature != signature {
            prefilterSignature = signature
            prefilterLastForwardedNanoseconds = now
            return true
        }
        let lastForwarded = prefilterLastForwardedNanoseconds ?? 0
        guard now >= lastForwarded,
            now - lastForwarded >= CaptureConstants.staticHeartbeatIntervalNanoseconds
        else {
            return false
        }
        prefilterLastForwardedNanoseconds = now
        return true
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stateLock.withLock {
            writerErrors.append(String(describing: error))
        }
    }

    @objc private func handleWillSleep() {
        stateLock.withLock {
            lifecycleSuspended = true
            epoch = nil
        }
    }

    @objc private func handleDidWake() {
        stateLock.withLock {
            lifecycleSuspended = false
        }
    }

    private func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
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

private struct ResolvedTarget {
    let focused: FocusedWindowDescriptor
    let approved: ShareableWindowDescriptor
    let scWindow: SCWindow
    let dimensions: PixelSize
}

private enum TargetResolution {
    case approved(ResolvedTarget)
    case gap(CaptureGapReason)

    func get() throws -> ResolvedTarget {
        switch self {
        case .approved(let target):
            target
        case .gap(let reason):
            throw CaptureSpikeError.windowResolution(reason)
        }
    }
}

private enum FocusedWindowReader {
    static func current() -> FocusedWindowDescriptor? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement,
                "AXFocusedWindow" as CFString,
                &focusedValue
            ) == .success, let focusedValue
        else {
            return nil
        }
        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
        guard
            let position = pointAttribute("AXPosition", from: focusedElement),
            let size = sizeAttribute("AXSize", from: focusedElement)
        else {
            return nil
        }
        var titleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focusedElement, "AXTitle" as CFString, &titleValue)
        var minimizedValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            focusedElement, "AXMinimized" as CFString, &minimizedValue)
        return FocusedWindowDescriptor(
            processID: application.processIdentifier,
            bounds: PointRect(x: position.x, y: position.y, width: size.width, height: size.height),
            title: titleValue as? String,
            isMinimized: minimizedValue as? Bool ?? false
        )
    }

    private static func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value
        else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value
        else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}

extension FocusedWindowDescriptor {
    fileprivate var signature: String {
        [
            String(processID),
            String(format: "%.1f", bounds.x),
            String(format: "%.1f", bounds.y),
            String(format: "%.1f", bounds.width),
            String(format: "%.1f", bounds.height),
            title ?? "",
            String(isMinimized),
        ].joined(separator: "|")
    }
}

private enum LumaFrameInspector {
    static func signature(of pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return 0
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 1_469_598_103_934_665_603
        for gridY in 0..<64 {
            let y = min(height - 1, gridY * height / 64)
            for gridX in 0..<64 {
                let x = min(width - 1, gridX * width / 64)
                hash ^= UInt64(bytes[y * bytesPerRow + x])
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }

    static func containsSentinelContamination(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return true
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var extreme = 0
        let samples = 64 * 64
        for gridY in 0..<64 {
            let y = min(height - 1, gridY * height / 64)
            for gridX in 0..<64 {
                let x = min(width - 1, gridX * width / 64)
                let luma = bytes[y * bytesPerRow + x]
                if luma < 32 || luma > 224 {
                    extreme += 1
                }
            }
        }
        return extreme > samples / 8
    }
}

extension PointRect {
    fileprivate init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}

extension CMSampleBuffer {
    fileprivate var pixelDimensions: PixelSize {
        guard let imageBuffer else {
            return PixelSize(width: 0, height: 0)
        }
        return PixelSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

private final class BoundedShareableContentProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var leaseState = RefreshLeaseState()

    func content() async -> SCShareableContent? {
        let token = lock.withLock {
            leaseState.begin(
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                cooldownNanoseconds: 30_000_000_000
            )
        }
        guard let token else {
            return nil
        }
        let result = await withCheckedContinuation { continuation in
            let box = ShareableContentContinuationBox(continuation: continuation)
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ) { [weak self] content, error in
                self?.lock.withLock {
                    self?.leaseState.complete(token)
                }
                box.resolve(error == nil ? content.map(UnsafeSendableShareableContent.init) : nil)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                box.resolve(nil)
            }
        }
        return result?.value
    }
}

private final class ShareableContentContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UnsafeSendableShareableContent?, Never>?

    init(continuation: CheckedContinuation<UnsafeSendableShareableContent?, Never>) {
        self.continuation = continuation
    }

    func resolve(_ content: UnsafeSendableShareableContent?) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<UnsafeSendableShareableContent?, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: content)
    }
}

private struct UnsafeSendableShareableContent: @unchecked Sendable {
    let value: SCShareableContent
}
