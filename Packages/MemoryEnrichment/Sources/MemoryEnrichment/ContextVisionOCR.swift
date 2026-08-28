import CoreGraphics
import CoreText
import Foundation
import ImageIO
import NaturalLanguage
import Vision

public struct OCRGroundTruthWord: Codable, Equatable, Sendable {
    public let text: String
    public let bounds: ContextRect

    public init(text: String, bounds: ContextRect) {
        self.text = text
        self.bounds = bounds
    }
}

public struct RenderedOCRFixture {
    public let image: CGImage
    public let groundTruth: [OCRGroundTruthWord]
}

public enum S2OCRRendererError: Error, Equatable, Sendable {
    case cannotCreateBitmapContext
    case cannotCreateImage
    case imageIORuntimeQuarantined
}

public enum S2OCRRenderer {
    public static let width = 1_000
    public static let height = 700

    public static func render(_ fixture: S2OCRFixture) throws -> RenderedOCRFixture {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw S2OCRRendererError.cannotCreateBitmapContext
        }

        context.setFillColor(CGColor(gray: fixture.backgroundLuma, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.textMatrix = .identity

        let positions: [CGPoint] = [
            CGPoint(x: 90, y: 500),
            CGPoint(x: 545, y: 500),
            CGPoint(x: 90, y: 220),
            CGPoint(x: 545, y: 220),
        ]
        let fontSize: CGFloat = fixture.isHighContrastLatin ? 54 : 46
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let textColor = CGColor(gray: fixture.foregroundLuma, alpha: 1)
        var groundTruth: [OCRGroundTruthWord] = []

        for (word, position) in zip(fixture.words, positions) {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: textColor,
            ]
            let attributed = CFAttributedStringCreate(
                nil, word as CFString, attributes as CFDictionary)
            let line = CTLineCreateWithAttributedString(attributed!)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographicWidth = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            )
            context.textPosition = position
            CTLineDraw(line, context)

            let pixelBounds = CGRect(
                x: position.x,
                y: position.y - descent,
                width: typographicWidth,
                height: ascent + descent
            )
            groundTruth.append(
                OCRGroundTruthWord(
                    text: word,
                    bounds: ContextRect(
                        x: pixelBounds.minX / CGFloat(width),
                        y: pixelBounds.minY / CGFloat(height),
                        width: pixelBounds.width / CGFloat(width),
                        height: pixelBounds.height / CGFloat(height)
                    )
                )
            )
        }

        guard let image = context.makeImage() else {
            throw S2OCRRendererError.cannotCreateImage
        }
        return RenderedOCRFixture(image: image, groundTruth: groundTruth)
    }

    public static func pngData(for image: CGImage) throws -> Data {
        _ = image
        throw S2OCRRendererError.imageIORuntimeQuarantined
    }
}

public struct AppleVisionTextRecognizer: VisionTextRecognizing, Sendable {
    public init() {}

    public func recognize(_ input: OCRFrameInput) async throws -> [OCRRawObservation] {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeight = 0.02

            let handler = VNImageRequestHandler(
                cgImage: input.image,
                orientation: input.orientation.cgImagePropertyOrientation,
                options: [:]
            )
            try handler.perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let bounds = observation.boundingBox
                return OCRRawObservation(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    languageCode: detectedLanguage(for: candidate.string),
                    visionBounds: OCRNormalizedBounds(
                        x: bounds.origin.x,
                        y: bounds.origin.y,
                        width: bounds.width,
                        height: bounds.height
                    )
                )
            }
        }.value
    }
}

private func detectedLanguage(for text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue ?? "en"
}

extension OCRImageOrientation {
    fileprivate var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        }
    }
}

public struct VisionContextOCR: Sendable {
    public init() {}

    public func recognize(_ image: CGImage) async throws -> [ContextTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let bounds = observation.boundingBox
            return ContextTextObservation(
                text: candidate.string,
                source: .visionOCR,
                bounds: ContextRect(
                    x: bounds.origin.x,
                    y: bounds.origin.y,
                    width: bounds.width,
                    height: bounds.height
                ),
                confidence: Double(candidate.confidence)
            )
        }
    }
}

public struct OCRRecallMetrics: Codable, Equatable, Sendable {
    public let totalGroundTruthWords: Int
    public let matchedGroundTruthWords: Int
    public let wordRecall: Double
}

public enum OCRRecallScorer {
    public static func score(
        groundTruth: [OCRGroundTruthWord],
        observations: [ContextTextObservation],
        minimumIntersectionOverUnion: Double
    ) -> OCRRecallMetrics {
        var usedObservationIndices: Set<Int> = []
        var matches = 0
        for expected in groundTruth {
            let expectedKey = ContextTextNormalizer.comparisonKey(expected.text)
            let match = observations.indices.first { index in
                guard !usedObservationIndices.contains(index),
                    observations[index].normalizedText == expectedKey,
                    let bounds = observations[index].bounds
                else {
                    return false
                }
                return expected.bounds.intersectionOverUnion(with: bounds)
                    >= minimumIntersectionOverUnion
            }
            if let match {
                usedObservationIndices.insert(match)
                matches += 1
            }
        }
        return OCRRecallMetrics(
            totalGroundTruthWords: groundTruth.count,
            matchedGroundTruthWords: matches,
            wordRecall: groundTruth.isEmpty ? 1 : Double(matches) / Double(groundTruth.count)
        )
    }
}
