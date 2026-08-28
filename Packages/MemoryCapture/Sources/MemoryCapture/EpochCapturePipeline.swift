import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

public protocol EpochIDGenerating: Sendable {
    func nextID() -> UUID
}

public struct RandomEpochIDGenerator: EpochIDGenerating {
    public init() {}

    public func nextID() -> UUID {
        UUID()
    }
}

public struct ApprovedWindowCaptureRequest: @unchecked Sendable, Equatable {
    public let target: ForegroundWindowCaptureTarget
    public let bundleIdentifier: String
    public let approvedBounds: PointRect
    public let policyDecisionID: UUID

    public init(
        target: ForegroundWindowCaptureTarget,
        bundleIdentifier: String,
        approvedBounds: PointRect,
        policyDecisionID: UUID
    ) {
        self.target = target
        self.bundleIdentifier = bundleIdentifier
        self.approvedBounds = approvedBounds
        self.policyDecisionID = policyDecisionID
    }
}

public struct SingleWindowFilterReceipt: Equatable, Sendable {
    public let generation: UInt64
    public let targetWindowID: UInt32
    public let dimensions: PixelSize
    public let appliedNanoseconds: UInt64

    public init(
        generation: UInt64,
        targetWindowID: UInt32,
        dimensions: PixelSize,
        appliedNanoseconds: UInt64
    ) {
        self.generation = generation
        self.targetWindowID = targetWindowID
        self.dimensions = dimensions
        self.appliedNanoseconds = appliedNanoseconds
    }
}

public protocol SingleWindowFilterUpdating: Sendable {
    func apply(
        target: ForegroundWindowCaptureTarget,
        generation: UInt64,
        dimensions: PixelSize
    ) async throws -> SingleWindowFilterReceipt
    func stop() async
}

public enum SingleWindowFilterUpdateError: Error, Equatable, Sendable {
    case ineligibleTarget
    case missingScreenCaptureKitWindow
}

private enum EpochStreamConfiguration {
    static func make(dimensions: PixelSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
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
        return configuration
    }
}

/// Owns one ScreenCaptureKit stream and swaps only its desktop-independent window filter.
/// Each output adapter is immutable and tags queued callbacks with the generation that created it.
public actor ScreenCaptureKitEpochStream: SingleWindowFilterUpdating {
    private struct RunningStream {
        let stream: SCStream
        let output: EpochFilterStreamOutput
    }

    private let frameHandler: @Sendable (ForegroundWindowPixelBuffer) -> Void
    private let sampleQueue = DispatchQueue(
        label: "com.justinhou.deepshelves.epoch-window-stream"
    )
    private var running: RunningStream?

    public init(
        frameHandler: @escaping @Sendable (ForegroundWindowPixelBuffer) -> Void
    ) {
        self.frameHandler = frameHandler
    }

    public func apply(
        target: ForegroundWindowCaptureTarget,
        generation: UInt64,
        dimensions: PixelSize
    ) async throws -> SingleWindowFilterReceipt {
        guard target.isEligibleForegroundWindow else {
            throw SingleWindowFilterUpdateError.ineligibleTarget
        }
        guard let window = target.screenCaptureKitWindow else {
            throw SingleWindowFilterUpdateError.missingScreenCaptureKitWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = EpochStreamConfiguration.make(dimensions: dimensions)
        let output = EpochFilterStreamOutput(
            targetWindowID: target.windowID,
            filterGeneration: generation,
            frameHandler: frameHandler
        )

        if let prior = running {
            try? prior.stream.removeStreamOutput(prior.output, type: .screen)
            running = nil
            do {
                try await prior.stream.updateContentFilter(filter)
                try await prior.stream.updateConfiguration(configuration)
                try prior.stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: sampleQueue
                )
                running = RunningStream(stream: prior.stream, output: output)
            } catch {
                try? await prior.stream.stopCapture()
                throw error
            }
        } else {
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: sampleQueue
            )
            do {
                try await stream.startCapture()
                running = RunningStream(stream: stream, output: output)
            } catch {
                try? stream.removeStreamOutput(output, type: .screen)
                throw error
            }
        }

        return SingleWindowFilterReceipt(
            generation: generation,
            targetWindowID: target.windowID,
            dimensions: dimensions,
            appliedNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    public func stop() async {
        guard let prior = running else { return }
        running = nil
        try? await prior.stream.stopCapture()
        try? prior.stream.removeStreamOutput(prior.output, type: .screen)
    }
}

private final class EpochFilterStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private let targetWindowID: UInt32
    private let filterGeneration: UInt64
    private let frameHandler: @Sendable (ForegroundWindowPixelBuffer) -> Void

    init(
        targetWindowID: UInt32,
        filterGeneration: UInt64,
        frameHandler: @escaping @Sendable (ForegroundWindowPixelBuffer) -> Void
    ) {
        self.targetWindowID = targetWindowID
        self.filterGeneration = filterGeneration
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
                capturedNanoseconds: DispatchTime.now().uptimeNanoseconds,
                filterGeneration: filterGeneration
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

public enum WindowCaptureEpochManagerError: Error, Equatable, Sendable {
    case invalidFilterReceipt
}

public actor WindowCaptureEpochManager {
    private let filterUpdater: any SingleWindowFilterUpdating
    private let clock: any ActivityMonotonicClock
    private let idGenerator: any EpochIDGenerating
    private var transitionRevision: UInt64 = 0
    private var filterTail: Task<SingleWindowFilterReceipt, Error>?
    private var activeEpoch: WindowCaptureEpoch?
    private var transitionLatenciesNanoseconds: [UInt64] = []

    public init(
        filterUpdater: any SingleWindowFilterUpdating,
        clock: any ActivityMonotonicClock = SystemActivityMonotonicClock(),
        idGenerator: any EpochIDGenerating = RandomEpochIDGenerator()
    ) {
        self.filterUpdater = filterUpdater
        self.clock = clock
        self.idGenerator = idGenerator
    }

    public func transition(
        to request: ApprovedWindowCaptureRequest,
        startedNanoseconds: UInt64? = nil
    ) async throws -> WindowCaptureEpoch? {
        transitionRevision &+= 1
        let revision = transitionRevision
        activeEpoch = nil
        let dimensions = CaptureGeometry.encodedSize(for: request.approvedBounds)
        let transitionStarted = startedNanoseconds ?? clock.nowNanoseconds()
        let preceding = filterTail
        let updater = filterUpdater
        let task = Task<SingleWindowFilterReceipt, Error> {
            if let preceding {
                _ = try? await preceding.value
            }
            return try await updater.apply(
                target: request.target,
                generation: revision,
                dimensions: dimensions
            )
        }
        filterTail = task
        let receipt = try await task.value
        guard transitionRevision == revision else {
            return nil
        }
        guard receipt.generation == revision,
            receipt.targetWindowID == request.target.windowID,
            receipt.dimensions == dimensions
        else {
            throw WindowCaptureEpochManagerError.invalidFilterReceipt
        }
        let epoch = WindowCaptureEpoch(
            id: idGenerator.nextID(),
            targetWindowID: request.target.windowID,
            processID: request.target.processID,
            bundleIdentifier: request.bundleIdentifier,
            approvedBounds: request.approvedBounds,
            policyDecisionID: request.policyDecisionID,
            encodedSize: dimensions,
            filterGeneration: receipt.generation,
            filterAppliedNanoseconds: receipt.appliedNanoseconds
        )
        activeEpoch = epoch
        transitionLatenciesNanoseconds.append(
            Self.elapsed(from: transitionStarted, to: receipt.appliedNanoseconds)
        )
        return epoch
    }

    public func revoke() {
        transitionRevision &+= 1
        activeEpoch = nil
    }

    public func stop() async {
        revoke()
        await filterUpdater.stop()
    }

    public func currentEpoch() -> WindowCaptureEpoch? {
        activeEpoch
    }

    public func transitionLatencyP95Nanoseconds() -> UInt64? {
        guard !transitionLatenciesNanoseconds.isEmpty else {
            return nil
        }
        let ordered = transitionLatenciesNanoseconds.sorted()
        let rank = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
        return ordered[rank]
    }

    private static func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

public struct FinalEpochFrameAdmissionResult: Equatable, Sendable {
    public let admission: FrameAdmissionDecision
    public let policyDecision: PrivacyPolicyDecision
}

public struct FinalEpochFrameAdmissionGate: Sendable {
    private let privacyPolicy: PrivacyPolicy

    public init(privacyPolicy: PrivacyPolicy) {
        self.privacyPolicy = privacyPolicy
    }

    public func evaluate(
        _ candidate: FrameCandidate,
        against epoch: WindowCaptureEpoch,
        approval: PrivacyPolicyApproval,
        currentContext: PrivacyEvaluationContext,
        epochIsActive: Bool = true
    ) async -> FinalEpochFrameAdmissionResult {
        let policyDecision = await privacyPolicy.finalRecheck(
            approval: approval,
            context: currentContext
        )
        let checkedCandidate = FrameCandidate(
            epochID: candidate.epochID,
            targetWindowID: candidate.targetWindowID,
            focusedWindowID: candidate.focusedWindowID,
            dimensions: candidate.dimensions,
            deliveredNanoseconds: candidate.deliveredNanoseconds,
            policyApproved: policyDecision.isAllowed,
            filterGeneration: candidate.filterGeneration,
            policyDecisionID: candidate.policyDecisionID
        )
        return FinalEpochFrameAdmissionResult(
            admission: FrameAdmission.evaluate(
                checkedCandidate,
                against: epoch,
                epochIsActive: epochIsActive
            ),
            policyDecision: policyDecision
        )
    }
}

public enum LuminanceSignatureError: Error, Equatable, Sendable {
    case invalidSampleCount(Int)
    case inaccessiblePixelBuffer
}

public struct LuminanceSignature: Equatable, Sendable {
    public static let gridWidth = 64
    public static let gridHeight = 64
    public static let sampleCount = gridWidth * gridHeight

    public let samples: [UInt8]

    public init(samples: [UInt8]) throws {
        guard samples.count == Self.sampleCount else {
            throw LuminanceSignatureError.invalidSampleCount(samples.count)
        }
        self.samples = samples
    }

    public init(pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let isPlanar = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
        let width =
            isPlanar
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height =
            isPlanar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow =
            isPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress =
            isPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)
        guard width > 0, height > 0, let baseAddress else {
            throw LuminanceSignatureError.inaccessiblePixelBuffer
        }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity(Self.sampleCount)
        for gridY in 0..<Self.gridHeight {
            let y = min(height - 1, gridY * height / Self.gridHeight)
            for gridX in 0..<Self.gridWidth {
                let x = min(width - 1, gridX * width / Self.gridWidth)
                samples.append(bytes[y * bytesPerRow + x])
            }
        }
        self.samples = samples
    }

    public func meanAbsoluteDifference(from other: Self) -> Double {
        let total = zip(samples, other.samples).reduce(into: UInt64(0)) { sum, pair in
            sum += UInt64(abs(Int(pair.0) - Int(pair.1)))
        }
        return Double(total) / Double(Self.sampleCount)
    }

    public func isVisualChange(from other: Self, threshold: Double) -> Bool {
        meanAbsoluteDifference(from: other) >= threshold
    }
}

public struct MeasuredFrameAcceptanceResult: Equatable, Sendable {
    public let decision: FrameAcceptanceDecision
    public let meanAbsoluteDifference: Double?
}

public struct MeasuredFrameAcceptanceGate: Sendable {
    private let visualDifferenceThreshold: Double
    private var epochID: UUID?
    private var lastAcceptedNanoseconds: UInt64?
    private var lastIndexedNanoseconds: UInt64?
    private var lastSignature: LuminanceSignature?

    public init(visualDifferenceThreshold: Double) {
        precondition(visualDifferenceThreshold >= 0)
        self.visualDifferenceThreshold = visualDifferenceThreshold
    }

    public mutating func evaluate(
        epochID candidateEpochID: UUID,
        timestampNanoseconds: UInt64,
        signature: LuminanceSignature,
        lastActivityNanoseconds: UInt64
    ) -> MeasuredFrameAcceptanceResult {
        if epochID != candidateEpochID {
            epochID = candidateEpochID
            lastAcceptedNanoseconds = timestampNanoseconds
            lastIndexedNanoseconds = timestampNanoseconds
            lastSignature = signature
            return result(.accepted(index: true, reason: .firstEpochFrame), difference: nil)
        }
        if Self.elapsed(from: lastActivityNanoseconds, to: timestampNanoseconds)
            >= CaptureConstants.idleSuspendIntervalNanoseconds
        {
            return result(.rejected(.idleSuspended), difference: nil)
        }
        guard let lastSignature else {
            return result(.accepted(index: true, reason: .firstEpochFrame), difference: nil)
        }
        let difference = signature.meanAbsoluteDifference(from: lastSignature)
        let sinceAccepted = Self.elapsed(
            from: lastAcceptedNanoseconds ?? 0,
            to: timestampNanoseconds
        )
        if difference >= visualDifferenceThreshold {
            guard sinceAccepted >= CaptureConstants.activeAcceptanceIntervalNanoseconds else {
                return result(.rejected(.activeRateLimit), difference: difference)
            }
            return accept(
                timestampNanoseconds: timestampNanoseconds,
                signature: signature,
                reason: .visualChange,
                difference: difference
            )
        }
        guard sinceAccepted >= CaptureConstants.staticHeartbeatIntervalNanoseconds else {
            return result(.rejected(.staticDuplicate), difference: difference)
        }
        return accept(
            timestampNanoseconds: timestampNanoseconds,
            signature: signature,
            reason: .staticHeartbeat,
            difference: difference
        )
    }

    private mutating func accept(
        timestampNanoseconds: UInt64,
        signature: LuminanceSignature,
        reason: FrameAcceptanceReason,
        difference: Double
    ) -> MeasuredFrameAcceptanceResult {
        lastAcceptedNanoseconds = timestampNanoseconds
        lastSignature = signature
        let shouldIndex =
            Self.elapsed(
                from: lastIndexedNanoseconds ?? 0,
                to: timestampNanoseconds
            ) >= CaptureConstants.indexIntervalNanoseconds
        if shouldIndex {
            lastIndexedNanoseconds = timestampNanoseconds
        }
        return result(
            .accepted(index: shouldIndex, reason: reason),
            difference: difference
        )
    }

    private func result(
        _ decision: FrameAcceptanceDecision,
        difference: Double?
    ) -> MeasuredFrameAcceptanceResult {
        MeasuredFrameAcceptanceResult(
            decision: decision,
            meanAbsoluteDifference: difference
        )
    }

    private static func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

public struct QueuedCaptureFrame<Payload: Sendable>: Sendable {
    public let id: UUID
    public let epochID: UUID
    public let targetWindowID: UInt32
    public let deliveredNanoseconds: UInt64
    public let reason: FrameAcceptanceReason
    public let shouldIndex: Bool
    public let payload: Payload

    public init(
        id: UUID,
        epochID: UUID,
        targetWindowID: UInt32,
        deliveredNanoseconds: UInt64,
        reason: FrameAcceptanceReason,
        shouldIndex: Bool,
        payload: Payload
    ) {
        self.id = id
        self.epochID = epochID
        self.targetWindowID = targetWindowID
        self.deliveredNanoseconds = deliveredNanoseconds
        self.reason = reason
        self.shouldIndex = shouldIndex
        self.payload = payload
    }
}

public enum BackpressureDropReason: String, Equatable, Sendable {
    case staleEpoch
    case redundantHeartbeat
    case oldestCandidate
    case revoked
}

public struct DroppedCaptureFrame<Payload: Sendable>: Sendable {
    public let frame: QueuedCaptureFrame<Payload>
    public let reason: BackpressureDropReason
}

public struct BackpressureEnqueueResult<Payload: Sendable>: Sendable {
    public let accepted: Bool
    public let dropped: [DroppedCaptureFrame<Payload>]
}

public struct NewestFrameBackpressureQueue<Payload: Sendable>: Sendable {
    public let capacity: Int
    public private(set) var activeEpochID: UUID?
    public private(set) var frames: [QueuedCaptureFrame<Payload>] = []
    public private(set) var peakCount = 0

    public init(capacity: Int = CaptureConstants.mediaQueueCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { frames.count }

    @discardableResult
    public mutating func activate(epochID: UUID) -> [DroppedCaptureFrame<Payload>] {
        activeEpochID = epochID
        return drain(reason: .staleEpoch)
    }

    @discardableResult
    public mutating func revoke() -> [DroppedCaptureFrame<Payload>] {
        activeEpochID = nil
        return drain(reason: .revoked)
    }

    public mutating func enqueue(
        _ frame: QueuedCaptureFrame<Payload>
    ) -> BackpressureEnqueueResult<Payload> {
        guard frame.epochID == activeEpochID else {
            return BackpressureEnqueueResult(
                accepted: false,
                dropped: [DroppedCaptureFrame(frame: frame, reason: .staleEpoch)]
            )
        }
        var dropped: [DroppedCaptureFrame<Payload>] = []
        if frames.count == capacity {
            let dropIndex = frames.firstIndex(where: { $0.reason == .staticHeartbeat }) ?? 0
            let removed = frames.remove(at: dropIndex)
            dropped.append(
                DroppedCaptureFrame(
                    frame: removed,
                    reason: removed.reason == .staticHeartbeat
                        ? .redundantHeartbeat
                        : .oldestCandidate
                )
            )
        }
        frames.append(frame)
        peakCount = max(peakCount, frames.count)
        return BackpressureEnqueueResult(accepted: true, dropped: dropped)
    }

    public mutating func dequeue() -> QueuedCaptureFrame<Payload>? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    private mutating func drain(
        reason: BackpressureDropReason
    ) -> [DroppedCaptureFrame<Payload>] {
        defer { frames.removeAll(keepingCapacity: true) }
        return frames.map { DroppedCaptureFrame(frame: $0, reason: reason) }
    }
}
