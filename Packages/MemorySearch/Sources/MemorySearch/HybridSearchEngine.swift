import CryptoKit
import Foundation
import MemoryContracts

public enum HybridSearchError: Error, Equatable, Sendable {
    case invalidCursorSigningKey
    case invalidCursor
    case cursorQueryMismatch
    case expiredAccessPolicy
    case unsupportedMode
    case inconsistentComponentProjection
    case invalidGroupingMetadata
}

public struct HybridFusionConfiguration: Equatable, Sendable {
    public let reciprocalRankK: Double
    public let exactFrameIdentifierBoost: Double
    public let exactTitleBoost: Double
    public let exactApplicationBoost: Double
    public let exactURLBoost: Double
    public let maximumGroupGap: TimeInterval
    public let minimumTextJaccard: Double

    public init(
        reciprocalRankK: Double = 60,
        exactFrameIdentifierBoost: Double = 0.025,
        exactTitleBoost: Double = 0.020,
        exactApplicationBoost: Double = 0.015,
        exactURLBoost: Double = 0.010,
        maximumGroupGap: TimeInterval = 30,
        minimumTextJaccard: Double = 0.8
    ) {
        precondition(reciprocalRankK == 60)
        precondition(exactFrameIdentifierBoost >= 0)
        precondition(exactTitleBoost >= 0)
        precondition(exactApplicationBoost >= 0)
        precondition(exactURLBoost >= 0)
        precondition(maximumGroupGap >= 0)
        precondition((0...1).contains(minimumTextJaccard))
        self.reciprocalRankK = reciprocalRankK
        self.exactFrameIdentifierBoost = exactFrameIdentifierBoost
        self.exactTitleBoost = exactTitleBoost
        self.exactApplicationBoost = exactApplicationBoost
        self.exactURLBoost = exactURLBoost
        self.maximumGroupGap = maximumGroupGap
        self.minimumTextJaccard = minimumTextJaccard
    }
}

public struct HybridGroupingMetadata: Equatable, Sendable {
    public let frameID: UUID
    public let captureEpochID: UUID
    public let captureReason: String
    public let mediaSHA256: Data?
    public let approvedText: String?

    public init(
        frameID: UUID,
        captureEpochID: UUID,
        captureReason: String,
        mediaSHA256: Data?,
        approvedText: String?
    ) {
        self.frameID = frameID
        self.captureEpochID = captureEpochID
        self.captureReason = captureReason
        self.mediaSHA256 = mediaSHA256
        self.approvedText = approvedText
    }
}

public struct HybridGroupingMetadataProvider: Sendable {
    private let operation: @Sendable ([UUID]) throws -> [UUID: HybridGroupingMetadata]

    public init(
        operation: @escaping @Sendable ([UUID]) throws -> [UUID: HybridGroupingMetadata]
    ) {
        self.operation = operation
    }

    public func metadata(frameIDs: [UUID]) throws -> [UUID: HybridGroupingMetadata] {
        try operation(frameIDs)
    }
}

public final class HybridSearchEngine: @unchecked Sendable, SearchEngine {
    private let lexical: any SearchEngine
    private let visual: (any SearchEngine)?
    private let groupingProvider: HybridGroupingMetadataProvider?
    private let configuration: HybridFusionConfiguration
    private let cursorSigningKey: SymmetricKey
    private let now: @Sendable () -> Date

    public init(
        lexical: any SearchEngine,
        visual: (any SearchEngine)?,
        cursorSigningKey: Data,
        groupingProvider: HybridGroupingMetadataProvider? = nil,
        configuration: HybridFusionConfiguration = HybridFusionConfiguration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard cursorSigningKey.count >= 32 else {
            throw HybridSearchError.invalidCursorSigningKey
        }
        self.lexical = lexical
        self.visual = visual
        self.groupingProvider = groupingProvider
        self.configuration = configuration
        self.cursorSigningKey = SymmetricKey(data: cursorSigningKey)
        self.now = now
    }

    public func search(_ request: SearchRequest) async throws -> SearchPage {
        try Task.checkCancellation()
        try request.validate()
        guard request.mode == .hybrid else { throw HybridSearchError.unsupportedMode }
        try requireCurrent(request.accessPolicy)
        let fingerprint = try queryFingerprint(request)
        let cursor = try request.cursor.map {
            let payload = try decodeCursor($0)
            guard payload.queryFingerprint == fingerprint else {
                throw HybridSearchError.cursorQueryMismatch
            }
            guard payload.returnedCount >= 0,
                payload.returnedCount <= request.accessPolicy.maxResults,
                let frameID = UUID(uuidString: payload.frameID),
                let capturedAt = Self.decodeDate(payload.capturedAt)
            else {
                throw HybridSearchError.invalidCursor
            }
            return CursorBoundary(
                score: Double(bitPattern: payload.scoreBitPattern),
                capturedAt: capturedAt,
                frameID: frameID,
                returnedCount: payload.returnedCount
            )
        }
        let alreadyReturned = cursor?.returnedCount ?? 0
        let remaining = request.accessPolicy.maxResults - alreadyReturned
        guard remaining > 0 else { return try SearchPage(results: [], nextCursor: nil) }

        let lexicalRequest = try componentRequest(request, mode: .textOnly)
        let visualRequest = try componentRequest(request, mode: .visualOnly)
        async let lexicalPage = lexical.search(lexicalRequest)
        async let visualPage = optionalVisualPage(visualRequest)
        let componentPages = try await (lexicalPage, visualPage)
        try Task.checkCancellation()
        try requireCurrent(request.accessPolicy)

        var fused = try HybridRanker(configuration: configuration).fuse(
            query: request.query,
            lexical: componentPages.0.results,
            visual: componentPages.1?.results ?? [],
            allowImageResources: request.accessPolicy.allowImageResources
        )
        if let groupingProvider {
            let requestedFrameIDs = Set(fused.map(\.frameID))
            let metadata = try groupingProvider.metadata(frameIDs: fused.map(\.frameID))
            try Task.checkCancellation()
            try requireCurrent(request.accessPolicy)
            guard Set(metadata.keys).isSubset(of: requestedFrameIDs),
                metadata.allSatisfy({ $0.key == $0.value.frameID })
            else {
                throw HybridSearchError.invalidGroupingMetadata
            }
            fused = fused.filter { metadata[$0.frameID] != nil }
            fused = try HybridRanker(configuration: configuration).group(
                fused,
                metadata: metadata
            )
        }
        fused = Array(fused.prefix(request.accessPolicy.maxResults))
        if let cursor {
            fused = fused.filter { Self.follows($0, boundary: cursor) }
        }
        let pageLimit = min(request.pageSize, remaining)
        let visible = Array(fused.prefix(pageLimit))
        let nextCursor: SearchCursor?
        if fused.count > pageLimit,
            alreadyReturned + visible.count < request.accessPolicy.maxResults,
            let last = visible.last
        {
            nextCursor = try encodeCursor(
                CursorPayload(
                    version: 1,
                    queryFingerprint: fingerprint,
                    scoreBitPattern: last.fusedScore.bitPattern,
                    capturedAt: Self.encodeDate(last.capturedAt),
                    frameID: last.frameID.uuidString.lowercased(),
                    returnedCount: alreadyReturned + visible.count
                )
            )
        } else {
            nextCursor = nil
        }
        try Task.checkCancellation()
        try requireCurrent(request.accessPolicy)
        return try SearchPage(results: visible, nextCursor: nextCursor)
    }

    private func optionalVisualPage(_ request: SearchRequest) async throws -> SearchPage? {
        guard let visual else { return nil }
        do {
            return try await visual.search(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch VisualSearchError.modelUnavailable {
            return nil
        }
    }

    private func componentRequest(_ request: SearchRequest, mode: SearchMode) throws
        -> SearchRequest
    {
        try SearchRequest(
            query: request.query,
            interval: request.interval,
            bundleIDs: request.bundleIDs,
            hosts: request.hosts,
            mode: mode,
            pageSize: request.accessPolicy.maxResults,
            cursor: nil,
            accessPolicy: request.accessPolicy
        )
    }

    private func requireCurrent(_ policy: AccessPolicy) throws {
        guard now() < policy.expiresAt else { throw HybridSearchError.expiredAccessPolicy }
    }

    private func queryFingerprint(_ request: SearchRequest) throws -> String {
        let interval = request.interval ?? request.accessPolicy.allowedInterval
        let input = FingerprintInput(
            query: HybridRanker.normalize(request.query),
            intervalStart: Self.encodeDate(interval.start),
            intervalEnd: Self.encodeDate(interval.end),
            bundleIDs: request.bundleIDs.sorted(),
            hosts: request.hosts.sorted(),
            mode: request.mode.rawValue,
            policyID: request.accessPolicy.id.uuidString.lowercased(),
            policyBundleIDs: request.accessPolicy.allowedBundleIDs.sorted(),
            policyHosts: request.accessPolicy.allowedHosts.sorted(),
            allowImageResources: request.accessPolicy.allowImageResources,
            policyExpiresAt: Self.encodeDate(request.accessPolicy.expiresAt),
            policyMaxResults: request.accessPolicy.maxResults
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.hex(SHA256.hash(data: try encoder.encode(input)))
    }

    private func encodeCursor(_ payload: CursorPayload) throws -> SearchCursor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: cursorSigningKey)
        return try SearchCursor(token: Self.base64URL(data) + "." + Self.base64URL(Data(signature)))
    }

    private func decodeCursor(_ cursor: SearchCursor) throws -> CursorPayload {
        try cursor.validate()
        let parts = cursor.token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let data = Self.decodeBase64URL(String(parts[0])),
            let signature = Self.decodeBase64URL(String(parts[1])),
            HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: data,
                using: cursorSigningKey
            ),
            let payload = try? JSONDecoder().decode(CursorPayload.self, from: data),
            payload.version == 1,
            payload.scoreBitPattern & 0x7FF0_0000_0000_0000 != 0x7FF0_0000_0000_0000
        else {
            throw HybridSearchError.invalidCursor
        }
        return payload
    }

    private static func follows(_ result: SearchResult, boundary: CursorBoundary) -> Bool {
        if result.fusedScore != boundary.score { return result.fusedScore < boundary.score }
        if result.capturedAt != boundary.capturedAt {
            return result.capturedAt < boundary.capturedAt
        }
        return result.frameID.uuidString.lowercased()
            > boundary.frameID.uuidString.lowercased()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func encodeDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    private static func decodeDate(_ value: String) -> Date? {
        try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }

    private static func hex<D: Sequence>(_ data: D) -> String where D.Element == UInt8 {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

struct HybridRanker: Sendable {
    let configuration: HybridFusionConfiguration

    func fuse(
        query: String,
        lexical: [SearchResult],
        visual: [SearchResult],
        allowImageResources: Bool
    ) throws -> [SearchResult] {
        var accumulators: [UUID: Accumulator] = [:]
        try ingest(
            lexical,
            component: .lexical,
            allowImageResources: allowImageResources,
            into: &accumulators
        )
        try ingest(
            visual,
            component: .visual,
            allowImageResources: allowImageResources,
            into: &accumulators
        )
        let normalizedQuery = Self.normalize(query)
        let results = try accumulators.values.map { accumulator in
            try accumulator.result(
                exactBoost: exactBoost(query: normalizedQuery, result: accumulator.projection),
                allowImageResources: allowImageResources
            )
        }
        return results.sorted(by: Self.precedes)
    }

    func group(
        _ results: [SearchResult],
        metadata: [UUID: HybridGroupingMetadata]
    ) throws -> [SearchResult] {
        guard !results.isEmpty else { return [] }
        var parents = Array(results.indices)
        for left in results.indices {
            guard let leftMetadata = metadata[results[left].frameID] else { continue }
            for right in results.index(after: left)..<results.endIndex {
                guard let rightMetadata = metadata[results[right].frameID],
                    shouldGroup(
                        results[left], leftMetadata,
                        results[right], rightMetadata
                    )
                else { continue }
                union(left, right, parents: &parents)
            }
        }
        var strongestByRoot: [Int: SearchResult] = [:]
        for index in results.indices {
            let root = find(index, parents: &parents)
            if let existing = strongestByRoot[root] {
                if Self.precedes(results[index], existing) {
                    strongestByRoot[root] = results[index]
                }
            } else {
                strongestByRoot[root] = results[index]
            }
        }
        return strongestByRoot.values.sorted(by: Self.precedes)
    }

    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private func ingest(
        _ results: [SearchResult],
        component: Component,
        allowImageResources: Bool,
        into accumulators: inout [UUID: Accumulator]
    ) throws {
        var seen: Set<UUID> = []
        for (offset, result) in results.enumerated() {
            guard seen.insert(result.frameID).inserted else {
                throw HybridSearchError.inconsistentComponentProjection
            }
            let rank: Int
            switch component {
            case .lexical: rank = result.textRank ?? offset + 1
            case .visual: rank = result.visualRank ?? offset + 1
            }
            guard rank > 0 else { throw HybridSearchError.inconsistentComponentProjection }
            let contribution = 1 / (configuration.reciprocalRankK + Double(rank))
            if var accumulator = accumulators[result.frameID] {
                try accumulator.merge(
                    result,
                    component: component,
                    rank: rank,
                    contribution: contribution,
                    allowImageResources: allowImageResources
                )
                accumulators[result.frameID] = accumulator
            } else {
                accumulators[result.frameID] = Accumulator(
                    projection: result,
                    evidence: result.evidence,
                    textRank: component == .lexical ? rank : nil,
                    visualRank: component == .visual ? rank : nil,
                    reciprocalScore: contribution
                )
            }
        }
    }

    private func exactBoost(query: String, result: SearchResult) -> Double {
        guard !query.isEmpty else { return 0 }
        var boost = 0.0
        if query == result.frameID.uuidString.lowercased() {
            boost += configuration.exactFrameIdentifierBoost
        }
        if query == Self.normalize(result.foreground.windowTitle ?? "") {
            boost += configuration.exactTitleBoost
        }
        if query == Self.normalize(result.foreground.applicationName)
            || query == Self.normalize(result.foreground.bundleID)
        {
            boost += configuration.exactApplicationBoost
        }
        if let origin = result.browser?.origin {
            let fullURL = origin.scheme + "://" + origin.host + (origin.path ?? "")
            if query == Self.normalize(origin.host) || query == Self.normalize(fullURL) {
                boost += configuration.exactURLBoost
            }
        }
        return boost
    }

    private func shouldGroup(
        _ lhs: SearchResult,
        _ lhsMetadata: HybridGroupingMetadata,
        _ rhs: SearchResult,
        _ rhsMetadata: HybridGroupingMetadata
    ) -> Bool {
        guard lhs.foreground.bundleID == rhs.foreground.bundleID,
            Self.normalize(lhs.foreground.windowTitle ?? "")
                == Self.normalize(rhs.foreground.windowTitle ?? ""),
            lhs.browser?.origin.host == rhs.browser?.origin.host,
            abs(lhs.capturedAt.timeIntervalSince(rhs.capturedAt)) <= configuration.maximumGroupGap
        else { return false }
        if let leftHash = lhsMetadata.mediaSHA256,
            let rightHash = rhsMetadata.mediaSHA256,
            leftHash == rightHash
        {
            return true
        }
        if lhsMetadata.captureEpochID == rhsMetadata.captureEpochID {
            let later = lhs.capturedAt > rhs.capturedAt ? lhsMetadata : rhsMetadata
            if later.captureReason == "staticHeartbeat" { return true }
        }
        let lhsTokens = Self.tokens(lhsMetadata.approvedText)
        let rhsTokens = Self.tokens(rhsMetadata.approvedText)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return union > 0 && Double(intersection) / Double(union) >= configuration.minimumTextJaccard
    }

    private static func tokens(_ text: String?) -> Set<String> {
        guard let text else { return [] }
        let separators = CharacterSet.alphanumerics.inverted
        return Set(
            text.lowercased().components(separatedBy: separators)
                .filter { !$0.isEmpty }
        )
    }

    private func find(_ index: Int, parents: inout [Int]) -> Int {
        if parents[index] != index { parents[index] = find(parents[index], parents: &parents) }
        return parents[index]
    }

    private func union(_ lhs: Int, _ rhs: Int, parents: inout [Int]) {
        let left = find(lhs, parents: &parents)
        let right = find(rhs, parents: &parents)
        if left != right { parents[right] = left }
    }

    static func precedes(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.fusedScore != rhs.fusedScore { return lhs.fusedScore > rhs.fusedScore }
        if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt > rhs.capturedAt }
        return lhs.frameID.uuidString.lowercased() < rhs.frameID.uuidString.lowercased()
    }

    private enum Component {
        case lexical
        case visual
    }

    private struct Accumulator {
        var projection: SearchResult
        var evidence: [SearchEvidence]
        var textRank: Int?
        var visualRank: Int?
        var reciprocalScore: Double

        mutating func merge(
            _ result: SearchResult,
            component: Component,
            rank: Int,
            contribution: Double,
            allowImageResources: Bool
        ) throws {
            guard projection.capturedAt == result.capturedAt,
                projection.foreground == result.foreground,
                projection.browser == result.browser
            else {
                throw HybridSearchError.inconsistentComponentProjection
            }
            evidence.append(contentsOf: result.evidence)
            switch component {
            case .lexical: textRank = rank
            case .visual: visualRank = rank
            }
            reciprocalScore += contribution
            if allowImageResources {
                if projection.thumbnailLocator == nil { projection = result }
            }
        }

        func result(exactBoost: Double, allowImageResources: Bool) throws -> SearchResult {
            var bestEvidence: [EvidenceKey: SearchEvidence] = [:]
            for item in evidence {
                let key = EvidenceKey(source: item.source, matchedText: item.matchedText)
                if bestEvidence[key].map({ $0.score < item.score }) ?? true {
                    bestEvidence[key] = item
                }
            }
            let orderedEvidence = bestEvidence.values.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.source.rawValue != $1.source.rawValue {
                    return $0.source.rawValue < $1.source.rawValue
                }
                return ($0.matchedText ?? "") < ($1.matchedText ?? "")
            }
            let mediaLocator: ContentLocator =
                allowImageResources
                ? projection.mediaLocator
                : .opaqueResourceID(
                    "hybrid-redacted-\(projection.frameID.uuidString.lowercased())"
                )
            return try SearchResult(
                frameID: projection.frameID,
                capturedAt: projection.capturedAt,
                foreground: projection.foreground,
                browser: projection.browser,
                thumbnailLocator: allowImageResources ? projection.thumbnailLocator : nil,
                mediaLocator: mediaLocator,
                evidence: orderedEvidence,
                textRank: textRank,
                visualRank: visualRank,
                fusedScore: reciprocalScore + exactBoost
            )
        }

        private struct EvidenceKey: Hashable {
            let source: SearchEvidenceSource
            let matchedText: String?
        }
    }
}

private struct CursorBoundary {
    let score: Double
    let capturedAt: Date
    let frameID: UUID
    let returnedCount: Int
}

private struct CursorPayload: Codable {
    let version: Int
    let queryFingerprint: String
    let scoreBitPattern: UInt64
    let capturedAt: String
    let frameID: String
    let returnedCount: Int
}

private struct FingerprintInput: Codable {
    let query: String
    let intervalStart: String
    let intervalEnd: String
    let bundleIDs: [String]
    let hosts: [String]
    let mode: String
    let policyID: String
    let policyBundleIDs: [String]
    let policyHosts: [String]
    let allowImageResources: Bool
    let policyExpiresAt: String
    let policyMaxResults: Int
}
