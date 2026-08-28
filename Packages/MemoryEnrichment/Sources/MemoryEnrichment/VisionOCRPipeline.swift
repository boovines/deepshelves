import CoreGraphics
import Foundation
import MemoryContracts

public enum OCRImageOrientation: String, Codable, CaseIterable, Sendable {
    case up
    case upMirrored
    case down
    case downMirrored
    case left
    case leftMirrored
    case right
    case rightMirrored
}

public struct OCRPixelRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRNormalizedBounds: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRFrameInput: @unchecked Sendable {
    public let image: CGImage
    public let orientation: OCRImageOrientation
    public let sourcePixelWidth: Int
    public let sourcePixelHeight: Int
    public let processedRegion: OCRPixelRect

    public init(
        image: CGImage,
        orientation: OCRImageOrientation,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        processedRegion: OCRPixelRect
    ) {
        self.image = image
        self.orientation = orientation
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.processedRegion = processedRegion
    }
}

public struct OCRRawObservation: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let languageCode: String?
    public let visionBounds: OCRNormalizedBounds

    public init(
        text: String,
        confidence: Float,
        languageCode: String?,
        visionBounds: OCRNormalizedBounds
    ) {
        self.text = text
        self.confidence = confidence
        self.languageCode = languageCode
        self.visionBounds = visionBounds
    }
}

public protocol VisionTextRecognizing: Sendable {
    func recognize(_ input: OCRFrameInput) async throws -> [OCRRawObservation]
}

public struct VisionOCRPipeline: Sendable {
    private let recognizer: any VisionTextRecognizing

    public init(recognizer: any VisionTextRecognizing) {
        self.recognizer = recognizer
    }

    public func recognize(
        _ input: OCRFrameInput,
        frameID: UUID,
        idProvider: (Int) -> UUID = { _ in UUID() }
    ) async throws -> [TextSpan] {
        guard Self.valid(input) else {
            return []
        }
        let observations = try await recognizer.recognize(input)
        try Task.checkCancellation()
        var spans: [TextSpan] = []
        for observation in observations {
            guard observation.confidence.isFinite,
                (0...1).contains(observation.confidence),
                let bounds = Self.projectedBounds(observation.visionBounds, input: input)
            else {
                continue
            }
            let normalizedText = TextSpan.normalize(observation.text)
            guard !normalizedText.isEmpty else {
                continue
            }
            let languageCode = Self.validLanguageCode(observation.languageCode)
            spans.append(
                try TextSpan(
                    id: idProvider(spans.count),
                    frameID: frameID,
                    source: .visionOCR,
                    text: normalizedText,
                    bounds: bounds,
                    confidence: observation.confidence,
                    languageCode: languageCode,
                    sensitivity: .normal
                )
            )
        }
        return spans
    }

    private static func valid(_ input: OCRFrameInput) -> Bool {
        input.sourcePixelWidth > 0 && input.sourcePixelHeight > 0
            && [
                input.processedRegion.x, input.processedRegion.y,
                input.processedRegion.width, input.processedRegion.height,
            ].allSatisfy(\.isFinite)
            && input.processedRegion.x >= 0 && input.processedRegion.y >= 0
            && input.processedRegion.width > 0 && input.processedRegion.height > 0
            && input.processedRegion.x + input.processedRegion.width
                <= Double(input.sourcePixelWidth)
            && input.processedRegion.y + input.processedRegion.height
                <= Double(input.sourcePixelHeight)
    }

    private static func projectedBounds(
        _ bounds: OCRNormalizedBounds,
        input: OCRFrameInput
    ) -> NormalizedRect? {
        let values = [bounds.x, bounds.y, bounds.width, bounds.height]
        guard values.allSatisfy(\.isFinite), bounds.x >= 0, bounds.y >= 0,
            bounds.width > 0, bounds.height > 0,
            bounds.x + bounds.width <= 1, bounds.y + bounds.height <= 1
        else {
            return nil
        }
        let region = input.processedRegion
        let sourceWidth = Double(input.sourcePixelWidth)
        let sourceHeight = Double(input.sourcePixelHeight)
        let x = (region.x + bounds.x * region.width) / sourceWidth
        let upperLeftY = 1 - bounds.y - bounds.height
        let y = (region.y + upperLeftY * region.height) / sourceHeight
        let width = bounds.width * region.width / sourceWidth
        let height = bounds.height * region.height / sourceHeight
        return try? NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private static func validLanguageCode(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 35,
            !value.contains(where: \.isWhitespace)
        else {
            return nil
        }
        return value
    }
}

public enum OCRThermalState: String, Codable, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct OCRJobLeaseRequest: Equatable, Sendable {
    public let jobID: UUID
    public let frameID: UUID
    public let attemptCount: Int

    public init(jobID: UUID, frameID: UUID, attemptCount: Int) {
        self.jobID = jobID
        self.frameID = frameID
        self.attemptCount = attemptCount
    }
}

public struct OCRJobLease: Equatable, Sendable {
    public let jobID: UUID
    public let frameID: UUID
    public let attemptCount: Int
    public let expiresAt: Date
}

public protocol OCRJobLeasePersisting: Sendable {
    func begin(_ lease: OCRJobLease, now: Date) async -> Bool
    func publish(_ lease: OCRJobLease, spans: [TextSpan]) async throws
    func cancel(_ lease: OCRJobLease) async
    func retry(_ lease: OCRJobLease, errorCode: String) async
    func failPermanently(_ lease: OCRJobLease, errorCode: String) async
}

public enum OCRJobDeferralReason: String, Codable, Equatable, Sendable {
    case thermalPressure
    case workerBusy
    case leaseUnavailable
}

public enum OCRJobExecutionOutcome: Equatable, Sendable {
    case succeeded([TextSpan])
    case deferred(OCRJobDeferralReason)
    case cancelled
    case retryableFailure(String)
    case permanentFailure(String)

    public var visibleStatus: String? {
        switch self {
        case .retryableFailure:
            "Text recognition will retry."
        case .permanentFailure:
            "Text recognition failed. The capture remains available without OCR text."
        case .succeeded, .deferred, .cancelled:
            nil
        }
    }
}

public actor VisionOCRWorker {
    public static let leaseDuration: TimeInterval = 120
    public static let errorCode = "vision_failed"

    private let pipeline: VisionOCRPipeline
    private let leaseStore: any OCRJobLeasePersisting
    private var activeJobID: UUID?

    public init(
        pipeline: VisionOCRPipeline,
        leaseStore: any OCRJobLeasePersisting
    ) {
        self.pipeline = pipeline
        self.leaseStore = leaseStore
    }

    public func run(
        job: OCRJobLeaseRequest,
        input: OCRFrameInput,
        thermalState: OCRThermalState,
        now: Date
    ) async -> OCRJobExecutionOutcome {
        guard thermalState == .nominal || thermalState == .fair else {
            return .deferred(.thermalPressure)
        }
        guard activeJobID == nil else {
            return .deferred(.workerBusy)
        }
        activeJobID = job.jobID
        defer { activeJobID = nil }

        let lease = OCRJobLease(
            jobID: job.jobID,
            frameID: job.frameID,
            attemptCount: job.attemptCount + 1,
            expiresAt: now.addingTimeInterval(Self.leaseDuration)
        )
        guard await leaseStore.begin(lease, now: now) else {
            return .deferred(.leaseUnavailable)
        }

        do {
            let spans = try await pipeline.recognize(input, frameID: job.frameID)
            try Task.checkCancellation()
            try await leaseStore.publish(lease, spans: spans)
            return .succeeded(spans)
        } catch is CancellationError {
            await leaseStore.cancel(lease)
            return .cancelled
        } catch {
            if lease.attemptCount < ProcessingJob.maximumAutomaticAttempts {
                await leaseStore.retry(lease, errorCode: Self.errorCode)
                return .retryableFailure(Self.errorCode)
            }
            await leaseStore.failPermanently(lease, errorCode: Self.errorCode)
            return .permanentFailure(Self.errorCode)
        }
    }
}
