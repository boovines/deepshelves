import Foundation

public enum TextSource: String, Codable, Equatable, Sendable {
    case accessibility
    case visionOCR
    case transcript
}

public enum TextSensitivity: String, Codable, Equatable, Sendable {
    case normal
    case redacted
    case suppressed
}

public struct TextSpan: Codable, Equatable, Sendable, ContractValidatable {
    public let id: UUID
    public let frameID: UUID
    public let source: TextSource
    public let text: String
    public let bounds: NormalizedRect?
    public let confidence: Float?
    public let languageCode: String?
    public let sensitivity: TextSensitivity

    public init(
        id: UUID,
        frameID: UUID,
        source: TextSource,
        text: String,
        bounds: NormalizedRect?,
        confidence: Float?,
        languageCode: String?,
        sensitivity: TextSensitivity
    ) throws {
        self.id = id
        self.frameID = frameID
        self.source = source
        self.text = Self.normalize(text)
        self.bounds = bounds
        self.confidence = confidence
        self.languageCode = languageCode
        self.sensitivity = sensitivity
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            !text.isEmpty && text == Self.normalize(text),
            field: "textSpan.text",
            violation: .inconsistent,
            detail: "text must be Unicode-normalized with collapsed whitespace"
        )
        try bounds?.validate()
        if let confidence {
            try ContractChecks.require(
                confidence.isFinite && (0...1).contains(confidence),
                field: "textSpan.confidence",
                violation: .outOfRange,
                detail: "confidence must be between zero and one"
            )
        }
        if source == .visionOCR {
            try ContractChecks.require(
                confidence != nil,
                field: "textSpan.confidence",
                violation: .missingRequiredValue,
                detail: "Vision OCR spans require confidence"
            )
        }
        if source == .accessibility {
            try ContractChecks.require(
                confidence == nil,
                field: "textSpan.confidence",
                violation: .inconsistent,
                detail: "Accessibility spans do not carry OCR confidence"
            )
        }
        if let languageCode {
            try ContractChecks.require(
                !languageCode.isEmpty && languageCode.count <= 35
                    && !languageCode.contains(where: \.isWhitespace),
                field: "textSpan.languageCode",
                violation: .outOfRange,
                detail: "language code must be a compact BCP 47 identifier"
            )
        }
    }

    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
