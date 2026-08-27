import Foundation

public enum ContentLocator: Equatable, Sendable, ContractValidatable {
    case archiveRelativePath(String)
    case opaqueResourceID(String)

    public func validate() throws {
        switch self {
        case .archiveRelativePath(let path):
            try ContractChecks.validateRelativePath(path, field: "contentLocator.path")
        case .opaqueResourceID(let identifier):
            try ContractChecks.require(
                !identifier.isEmpty && identifier.count <= 512 && !identifier.contains("/"),
                field: "contentLocator.opaqueResourceID",
                violation: .outOfRange,
                detail: "opaque resource identifier must be bounded and disclose no path"
            )
        }
    }
}

extension ContentLocator: Codable {
    private enum Kind: String, Codable {
        case archiveRelativePath
        case opaqueResourceID
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .archiveRelativePath:
            self = .archiveRelativePath(value)
        case .opaqueResourceID:
            self = .opaqueResourceID(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .archiveRelativePath(let path):
            try container.encode(Kind.archiveRelativePath, forKey: .kind)
            try container.encode(path, forKey: .value)
        case .opaqueResourceID(let identifier):
            try container.encode(Kind.opaqueResourceID, forKey: .kind)
            try container.encode(identifier, forKey: .value)
        }
    }
}

public enum SearchEvidenceSource: String, Codable, Equatable, Sendable {
    case accessibility
    case visionOCR
    case transcript
    case title
    case application
    case url
    case visual
}

public struct SearchEvidence: Codable, Equatable, Sendable, ContractValidatable {
    public let source: SearchEvidenceSource
    public let matchedText: String?
    public let score: Double

    public init(source: SearchEvidenceSource, matchedText: String?, score: Double) {
        self.source = source
        self.matchedText = matchedText.map(TextSpan.normalize)
        self.score = score
    }

    public func validate() throws {
        try ContractChecks.require(
            score.isFinite && score >= 0,
            field: "searchEvidence.score",
            violation: .outOfRange,
            detail: "evidence score must be finite and non-negative"
        )
        if source == .visual {
            try ContractChecks.require(
                matchedText == nil,
                field: "searchEvidence.matchedText",
                violation: .inconsistent,
                detail: "visual evidence does not invent matched source text"
            )
        } else if let matchedText {
            try ContractChecks.require(
                !matchedText.isEmpty && matchedText == TextSpan.normalize(matchedText),
                field: "searchEvidence.matchedText",
                violation: .inconsistent,
                detail: "matched text must be normalized source evidence"
            )
        }
    }
}

public struct SearchResult: Codable, Equatable, Sendable, ContractValidatable {
    public let frameID: UUID
    public let capturedAt: Date
    public let foreground: ForegroundContext
    public let browser: BrowserContext?
    public let thumbnailLocator: ContentLocator?
    public let mediaLocator: ContentLocator
    public let evidence: [SearchEvidence]
    public let textRank: Int?
    public let visualRank: Int?
    public let fusedScore: Double

    public init(
        frameID: UUID,
        capturedAt: Date,
        foreground: ForegroundContext,
        browser: BrowserContext?,
        thumbnailLocator: ContentLocator?,
        mediaLocator: ContentLocator,
        evidence: [SearchEvidence],
        textRank: Int?,
        visualRank: Int?,
        fusedScore: Double
    ) throws {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.foreground = foreground
        self.browser = browser
        self.thumbnailLocator = thumbnailLocator
        self.mediaLocator = mediaLocator
        self.evidence = evidence
        self.textRank = textRank
        self.visualRank = visualRank
        self.fusedScore = fusedScore
        try validate()
    }

    public func validate() throws {
        try foreground.validate()
        try browser?.validate()
        try ContractChecks.require(
            browser?.isPrivateContext != true,
            field: "searchResult.browser.isPrivateContext",
            violation: .inconsistent,
            detail: "private browser context cannot appear in search"
        )
        try thumbnailLocator?.validate()
        try mediaLocator.validate()
        try ContractChecks.require(
            !evidence.isEmpty,
            field: "searchResult.evidence",
            violation: .missingRequiredValue,
            detail: "results must cite at least one source evidence item"
        )
        for item in evidence {
            try item.validate()
        }
        try ContractChecks.require(
            textRank.map { $0 > 0 } ?? true,
            field: "searchResult.textRank",
            violation: .outOfRange,
            detail: "component ranks are one-based"
        )
        try ContractChecks.require(
            visualRank.map { $0 > 0 } ?? true,
            field: "searchResult.visualRank",
            violation: .outOfRange,
            detail: "component ranks are one-based"
        )
        try ContractChecks.require(
            fusedScore.isFinite && fusedScore >= 0,
            field: "searchResult.fusedScore",
            violation: .outOfRange,
            detail: "fused score must be finite and non-negative"
        )
    }
}

public struct SearchPage: Codable, Equatable, Sendable, ContractValidatable {
    public let results: [SearchResult]
    public let nextCursor: SearchCursor?

    public init(results: [SearchResult], nextCursor: SearchCursor?) throws {
        self.results = results.sorted(by: Self.precedes)
        self.nextCursor = nextCursor
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            results.count <= 100,
            field: "searchPage.results",
            violation: .outOfRange,
            detail: "a result page cannot exceed 100 items"
        )
        for result in results {
            try result.validate()
        }
        try nextCursor?.validate()
        try ContractChecks.require(
            results == results.sorted(by: Self.precedes),
            field: "searchPage.results",
            violation: .inconsistent,
            detail: "results must use score, time, then UUID stable ordering"
        )
    }

    private static func precedes(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.fusedScore != rhs.fusedScore {
            return lhs.fusedScore > rhs.fusedScore
        }
        if lhs.capturedAt != rhs.capturedAt {
            return lhs.capturedAt > rhs.capturedAt
        }
        return lhs.frameID.uuidString.lowercased() < rhs.frameID.uuidString.lowercased()
    }
}
