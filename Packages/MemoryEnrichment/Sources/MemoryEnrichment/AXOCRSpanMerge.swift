import Foundation
import MemoryContracts

public enum AXOCRSpanMergeError: Error, Equatable, Sendable {
    case frameMismatch(expected: UUID, actual: UUID)
    case sourceMismatch(expected: TextSource, actual: TextSource)
}

/// Merges only durable, redacted `TextSpan` projections. Raw AX nodes and Vision
/// observations deliberately cannot enter this boundary.
public struct AXOCRSpanMerger: Sendable {
    public static let duplicateIntersectionOverUnion = 0.5

    public init() {}

    public func merge<Accessibility: Sequence, OCR: Sequence>(
        frameID: UUID,
        accessibility: Accessibility,
        ocr: OCR
    ) throws -> [TextSpan]
    where Accessibility.Element == TextSpan, OCR.Element == TextSpan {
        let accessibilityValues = try validated(
            accessibility,
            frameID: frameID,
            expectedSource: .accessibility
        )
        let ocrValues = try validated(
            ocr,
            frameID: frameID,
            expectedSource: .visionOCR
        )
        let candidates = (accessibilityValues + ocrValues).sorted(by: preferredCandidate)
        var accepted: [TextSpan] = []

        for candidate in candidates where candidate.sensitivity != .suppressed {
            guard !accepted.contains(where: { isDuplicate(candidate, of: $0) }) else {
                continue
            }
            accepted.append(candidate)
        }

        return accepted.sorted(by: stableReadingOrder)
    }

    private func validated<S: Sequence>(
        _ spans: S,
        frameID: UUID,
        expectedSource: TextSource
    ) throws -> [TextSpan] where S.Element == TextSpan {
        try spans.map { span in
            guard span.frameID == frameID else {
                throw AXOCRSpanMergeError.frameMismatch(
                    expected: frameID,
                    actual: span.frameID
                )
            }
            guard span.source == expectedSource else {
                throw AXOCRSpanMergeError.sourceMismatch(
                    expected: expectedSource,
                    actual: span.source
                )
            }
            try span.validate()
            return span
        }
    }

    private func isDuplicate(_ left: TextSpan, of right: TextSpan) -> Bool {
        guard Self.comparisonKey(left.text) == Self.comparisonKey(right.text) else {
            return false
        }
        switch (left.bounds, right.bounds) {
        case (let leftBounds?, let rightBounds?):
            return intersectionOverUnion(leftBounds, rightBounds)
                >= Self.duplicateIntersectionOverUnion
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func preferredCandidate(_ left: TextSpan, _ right: TextSpan) -> Bool {
        let leftSource = sourceRank(left.source)
        let rightSource = sourceRank(right.source)
        if leftSource != rightSource { return leftSource < rightSource }

        let leftConfidence = left.confidence ?? 1
        let rightConfidence = right.confidence ?? 1
        if leftConfidence != rightConfidence { return leftConfidence > rightConfidence }

        let leftKey = Self.comparisonKey(left.text)
        let rightKey = Self.comparisonKey(right.text)
        if leftKey != rightKey { return leftKey < rightKey }

        let boundsComparison = compareBounds(left.bounds, right.bounds)
        if boundsComparison != .orderedSame { return boundsComparison == .orderedAscending }
        return left.id.uuidString < right.id.uuidString
    }

    private func stableReadingOrder(_ left: TextSpan, _ right: TextSpan) -> Bool {
        let boundsComparison = compareBounds(left.bounds, right.bounds)
        if boundsComparison != .orderedSame { return boundsComparison == .orderedAscending }

        let leftKey = Self.comparisonKey(left.text)
        let rightKey = Self.comparisonKey(right.text)
        if leftKey != rightKey { return leftKey < rightKey }

        let leftSource = sourceRank(left.source)
        let rightSource = sourceRank(right.source)
        if leftSource != rightSource { return leftSource < rightSource }
        return left.id.uuidString < right.id.uuidString
    }

    private func compareBounds(_ left: NormalizedRect?, _ right: NormalizedRect?)
        -> ComparisonResult
    {
        switch (left, right) {
        case (let left?, let right?):
            let leftValues = [left.y, left.x, left.height, left.width]
            let rightValues = [right.y, right.x, right.height, right.width]
            for (leftValue, rightValue) in zip(leftValues, rightValues) {
                if leftValue < rightValue { return .orderedAscending }
                if leftValue > rightValue { return .orderedDescending }
            }
            return .orderedSame
        case (_?, nil):
            return .orderedAscending
        case (nil, _?):
            return .orderedDescending
        case (nil, nil):
            return .orderedSame
        }
    }

    private func sourceRank(_ source: TextSource) -> Int {
        switch source {
        case .accessibility: 0
        case .visionOCR: 1
        case .transcript: 2
        }
    }

    private func intersectionOverUnion(_ left: NormalizedRect, _ right: NormalizedRect) -> Double {
        let intersectionWidth = max(
            0,
            min(left.x + left.width, right.x + right.width) - max(left.x, right.x)
        )
        let intersectionHeight = max(
            0,
            min(left.y + left.height, right.y + right.height) - max(left.y, right.y)
        )
        let intersection = intersectionWidth * intersectionHeight
        let union = left.width * left.height + right.width * right.height - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func comparisonKey(_ text: String) -> String {
        TextSpan.normalize(text).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

public enum ApprovedSearchMetadataProjectionError: Error, Equatable, Sendable {
    case emptyApprovedApplication
    case privateBrowserContext
    case unsupportedURLScheme(String)
}

public struct ApprovedSearchMetadataProjection: Codable, Equatable, Sendable, ContractValidatable {
    public let bundleID: String
    public let applicationName: String
    public let windowTitle: String?
    public let browserFamily: MemoryContracts.BrowserFamily?
    public let approvedURL: String?
    public let host: String?
    public let path: String?

    public init(
        bundleID: String,
        applicationName: String,
        windowTitle: String?,
        browserFamily: MemoryContracts.BrowserFamily?,
        approvedURL: String?,
        host: String?,
        path: String?
    ) throws {
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.browserFamily = browserFamily
        self.approvedURL = approvedURL
        self.host = host
        self.path = path
        try validate()
    }

    public func validate() throws {
        try requireProjection(
            !bundleID.isEmpty
                && bundleID == bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
            field: "approvedSearchMetadata.bundleID",
            violation: .inconsistent,
            detail: "bundle identifier must be a nonempty approved projection"
        )
        try requireProjection(
            !applicationName.isEmpty && applicationName == TextSpan.normalize(applicationName),
            field: "approvedSearchMetadata.applicationName",
            violation: .inconsistent,
            detail: "application name must be normalized"
        )
        if let windowTitle {
            try requireProjection(
                !windowTitle.isEmpty && windowTitle == TextSpan.normalize(windowTitle),
                field: "approvedSearchMetadata.windowTitle",
                violation: .inconsistent,
                detail: "window title must be a normalized approved projection"
            )
        }
        let browserFields: [Any?] = [browserFamily, approvedURL, host]
        let hasBrowser = browserFields.allSatisfy { $0 != nil }
        try requireProjection(
            hasBrowser || browserFields.allSatisfy { $0 == nil } && path == nil,
            field: "approvedSearchMetadata.browser",
            violation: .inconsistent,
            detail: "browser family, URL, and host must be present together"
        )
        guard hasBrowser, let approvedURL, let host else { return }
        let schemeSeparator = ":" + "/" + "/"
        let expectedPrefix = "https" + schemeSeparator + host
        let alternatePrefix = "http" + schemeSeparator + host
        try requireProjection(
            approvedURL == expectedPrefix + (path ?? "")
                || approvedURL == alternatePrefix + (path ?? ""),
            field: "approvedSearchMetadata.approvedURL",
            violation: .sensitiveURLComponent,
            detail: "URL must contain only the approved HTTP(S) origin and path"
        )
        try requireProjection(
            host == host.lowercased() && !host.contains("@") && !host.isEmpty,
            field: "approvedSearchMetadata.host",
            violation: .sensitiveURLComponent,
            detail: "host must be lowercase and contain no credentials"
        )
        if let path {
            try requireProjection(
                path.hasPrefix("/") && !path.contains("?") && !path.contains("#")
                    && !path.contains("@"),
                field: "approvedSearchMetadata.path",
                violation: .sensitiveURLComponent,
                detail: "path must omit query, fragment, and credentials"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        browserFamily = try container.decodeIfPresent(
            MemoryContracts.BrowserFamily.self,
            forKey: .browserFamily
        )
        approvedURL = try container.decodeIfPresent(String.self, forKey: .approvedURL)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        try validate()
    }
}

/// Projects only context that already passed foreground and browser policy.
/// Process IDs, raw URL candidates, queries, fragments, and credentials are not
/// fields of the resulting value and therefore cannot be persisted through it.
public struct ApprovedSearchMetadataProjector: Sendable {
    public init() {}

    public func project(
        foreground: ForegroundContext,
        browser: BrowserContext?
    ) throws -> ApprovedSearchMetadataProjection {
        try foreground.validate()
        let bundleID = foreground.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let applicationName = TextSpan.normalize(foreground.applicationName)
        guard !bundleID.isEmpty, !applicationName.isEmpty else {
            throw ApprovedSearchMetadataProjectionError.emptyApprovedApplication
        }
        let windowTitle = foreground.windowTitle.flatMap { title in
            let normalized = TextSpan.normalize(title)
            return normalized.isEmpty ? nil : normalized
        }

        guard let browser else {
            return try ApprovedSearchMetadataProjection(
                bundleID: bundleID,
                applicationName: applicationName,
                windowTitle: windowTitle,
                browserFamily: nil,
                approvedURL: nil,
                host: nil,
                path: nil
            )
        }
        try browser.validate()
        guard !browser.isPrivateContext else {
            throw ApprovedSearchMetadataProjectionError.privateBrowserContext
        }
        guard browser.origin.scheme == "https" || browser.origin.scheme == "http" else {
            throw ApprovedSearchMetadataProjectionError.unsupportedURLScheme(
                browser.origin.scheme
            )
        }
        let url =
            browser.origin.scheme + "://" + browser.origin.host
            + (browser.origin.path ?? "")
        return try ApprovedSearchMetadataProjection(
            bundleID: bundleID,
            applicationName: applicationName,
            windowTitle: windowTitle,
            browserFamily: browser.family,
            approvedURL: url,
            host: browser.origin.host,
            path: browser.origin.path
        )
    }
}

private func requireProjection(
    _ condition: @autoclosure () -> Bool,
    field: String,
    violation: ContractViolation,
    detail: String
) throws {
    guard condition() else {
        throw ContractValidationError(field: field, violation: violation, detail: detail)
    }
}
