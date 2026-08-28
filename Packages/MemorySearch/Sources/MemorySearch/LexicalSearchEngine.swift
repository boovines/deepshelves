import CryptoKit
import Foundation
import MemoryContracts
import MemoryStore

public enum LexicalSearchError: Error, Equatable, Sendable {
    case invalidCursorSigningKey
    case invalidCursor
    case cursorQueryMismatch
    case expiredAccessPolicy
    case visualSearchUnavailable
    case invalidStoredProjection
}

public final class LexicalSearchEngine: @unchecked Sendable {
    private let store: ArchiveSearchIndexStore
    private let cursorSigningKey: SymmetricKey
    private let now: @Sendable () -> Date

    public init(
        database: ArchiveDatabase,
        cursorSigningKey: Data,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard cursorSigningKey.count >= 32 else {
            throw LexicalSearchError.invalidCursorSigningKey
        }
        store = ArchiveSearchIndexStore(database: database)
        self.cursorSigningKey = SymmetricKey(data: cursorSigningKey)
        self.now = now
    }

    public func search(_ request: SearchRequest) async throws -> SearchPage {
        try Task.checkCancellation()
        try request.validate()
        guard now() < request.accessPolicy.expiresAt else {
            throw LexicalSearchError.expiredAccessPolicy
        }
        guard request.mode != .visualOnly else {
            throw LexicalSearchError.visualSearchUnavailable
        }

        let lexical = FTS5LiteralQuery(raw: request.query)
        let effectiveInterval = request.interval ?? request.accessPolicy.allowedInterval
        let fingerprint = try queryFingerprint(
            request: request,
            interval: effectiveInterval,
            normalizedQuery: lexical.normalizedQuery
        )
        let cursorPayload = try request.cursor.map {
            let payload = try decodeCursor($0)
            guard payload.queryFingerprint == fingerprint else {
                throw LexicalSearchError.cursorQueryMismatch
            }
            guard payload.returnedCount >= 0,
                payload.returnedCount <= request.accessPolicy.maxResults
            else {
                throw LexicalSearchError.invalidCursor
            }
            return payload
        }
        let after = try cursorPayload.map { payload in
            guard let frameID = UUID(uuidString: payload.frameID),
                let capturedAt = Self.decodeDate(payload.capturedAt)
            else {
                throw LexicalSearchError.invalidCursor
            }
            return ArchiveLexicalCursorTuple(
                score: Double(bitPattern: payload.scoreBitPattern),
                capturedAt: capturedAt,
                frameID: frameID
            )
        }

        guard !request.accessPolicy.allowedBundleIDs.isEmpty else {
            return try SearchPage(results: [], nextCursor: nil)
        }
        guard lexical.ftsQuery != nil || !request.bundleIDs.isEmpty || !request.hosts.isEmpty else {
            return try SearchPage(results: [], nextCursor: nil)
        }
        let alreadyReturned = cursorPayload?.returnedCount ?? 0
        let remaining = request.accessPolicy.maxResults - alreadyReturned
        guard remaining > 0 else {
            return try SearchPage(results: [], nextCursor: nil)
        }
        let pageLimit = min(request.pageSize, remaining)

        let candidates = try store.lexicalCandidates(
            ArchiveLexicalQuery(
                ftsQuery: lexical.ftsQuery,
                normalizedQuery: lexical.normalizedQuery,
                interval: effectiveInterval,
                policyBundleIDs: request.accessPolicy.allowedBundleIDs,
                policyHosts: request.accessPolicy.allowedHosts,
                requestedBundleIDs: request.bundleIDs,
                requestedHosts: request.hosts,
                after: after,
                limit: pageLimit + 1
            )
        )
        try Task.checkCancellation()

        let visible = Array(candidates.prefix(pageLimit))
        let results = try visible.map { candidate in
            try project(candidate, lexical: lexical, request: request)
        }
        let nextCursor: SearchCursor?
        if candidates.count > pageLimit,
            alreadyReturned + visible.count < request.accessPolicy.maxResults,
            let last = visible.last
        {
            nextCursor = try encodeCursor(
                CursorPayload(
                    version: 1,
                    queryFingerprint: fingerprint,
                    scoreBitPattern: last.score.bitPattern,
                    capturedAt: Self.encodeDate(last.capturedAt),
                    frameID: last.frameID.uuidString.lowercased(),
                    returnedCount: alreadyReturned + visible.count
                )
            )
        } else {
            nextCursor = nil
        }
        try Task.checkCancellation()
        return try SearchPage(results: results, nextCursor: nextCursor)
    }

    private func project(
        _ candidate: ArchiveLexicalCandidate,
        lexical: FTS5LiteralQuery,
        request: SearchRequest
    ) throws -> SearchResult {
        let foreground = try ForegroundContext(
            bundleID: candidate.bundleIdentifier,
            applicationName: candidate.applicationName,
            processID: nil,
            windowTitle: candidate.windowTitle,
            windowBounds: candidate.windowBounds
        )
        let browser: BrowserContext?
        if let host = candidate.urlHost {
            guard let family = candidate.browserFamily, let scheme = candidate.urlScheme else {
                throw LexicalSearchError.invalidStoredProjection
            }
            browser = try BrowserContext(
                family: family,
                origin: BrowserOrigin(scheme: scheme, host: host, path: candidate.urlPath),
                isPrivateContext: false
            )
        } else {
            browser = nil
        }
        let mediaLocator: ContentLocator
        if let path = candidate.mediaPath {
            mediaLocator = .archiveRelativePath(path)
        } else {
            mediaLocator = .opaqueResourceID(
                "legacy-frame-(candidate.frameID.uuidString.lowercased())"
            )
        }
        let thumbnail = candidate.thumbnailPath.map(ContentLocator.archiveRelativePath)
        let evidence = evidence(candidate, lexical: lexical, request: request)
        guard !evidence.isEmpty else {
            throw LexicalSearchError.invalidStoredProjection
        }
        return try SearchResult(
            frameID: candidate.frameID,
            capturedAt: candidate.capturedAt,
            foreground: foreground,
            browser: browser,
            thumbnailLocator: thumbnail,
            mediaLocator: mediaLocator,
            evidence: evidence,
            textRank: candidate.textRank,
            visualRank: nil,
            fusedScore: candidate.score
        )
    }

    private func evidence(
        _ candidate: ArchiveLexicalCandidate,
        lexical: FTS5LiteralQuery,
        request: SearchRequest
    ) -> [SearchEvidence] {
        var evidence: [SearchEvidence] = []
        for span in candidate.spans where lexical.matches(span.text) {
            let source: SearchEvidenceSource
            let score: Double
            switch span.source {
            case .accessibility:
                source = .accessibility
                score = 6
            case .visionOCR:
                source = .visionOCR
                score = 3
            case .transcript:
                source = .transcript
                score = 1
            }
            evidence.append(SearchEvidence(source: source, matchedText: span.text, score: score))
        }
        if lexical.matches(candidate.windowTitle) {
            evidence.append(
                SearchEvidence(source: .title, matchedText: candidate.windowTitle, score: 4)
            )
        }
        if lexical.matches(candidate.applicationName)
            || request.bundleIDs.contains(candidate.bundleIdentifier)
        {
            evidence.append(
                SearchEvidence(
                    source: .application,
                    matchedText: candidate.applicationName,
                    score: 3
                )
            )
        }
        if lexical.matches(candidate.urlHost) || lexical.matches(candidate.urlPath)
            || candidate.urlHost.map(request.hosts.contains) == true
        {
            let urlEvidence = [candidate.urlHost, candidate.urlPath]
                .compactMap { $0 }
                .joined(separator: " ")
            if !urlEvidence.isEmpty {
                evidence.append(SearchEvidence(source: .url, matchedText: urlEvidence, score: 2.5))
            }
        }
        if lexical.matches(candidate.transcriptText),
            !evidence.contains(where: { $0.source == .transcript })
        {
            evidence.append(
                SearchEvidence(
                    source: .transcript,
                    matchedText: candidate.transcriptText,
                    score: 1
                )
            )
        }
        var seen: Set<EvidenceKey> = []
        return
            evidence
            .filter {
                seen.insert(EvidenceKey(source: $0.source, text: $0.matchedText ?? "")).inserted
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.source.rawValue != $1.source.rawValue {
                    return $0.source.rawValue < $1.source.rawValue
                }
                return ($0.matchedText ?? "") < ($1.matchedText ?? "")
            }
    }

    private func queryFingerprint(
        request: SearchRequest,
        interval: DateInterval,
        normalizedQuery: String
    ) throws -> String {
        let input = FingerprintInput(
            normalizedQuery: normalizedQuery,
            intervalStart: Self.encodeDate(interval.start),
            intervalEnd: Self.encodeDate(interval.end),
            bundleIDs: request.bundleIDs.sorted(),
            hosts: request.hosts.sorted(),
            mode: request.mode.rawValue,
            policyID: request.accessPolicy.id.uuidString.lowercased(),
            policyBundleIDs: request.accessPolicy.allowedBundleIDs.sorted(),
            policyHosts: request.accessPolicy.allowedHosts.sorted(),
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
        let payloadData = try encoder.encode(payload)
        let signature = HMAC<SHA256>.authenticationCode(
            for: payloadData,
            using: cursorSigningKey
        )
        return try SearchCursor(
            token: Self.base64URL(payloadData) + "." + Self.base64URL(Data(signature))
        )
    }

    private func decodeCursor(_ cursor: SearchCursor) throws -> CursorPayload {
        try cursor.validate()
        let components = cursor.token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
            let payloadData = Self.decodeBase64URL(String(components[0])),
            let signature = Self.decodeBase64URL(String(components[1])),
            HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: payloadData,
                using: cursorSigningKey
            ),
            let payload = try? JSONDecoder().decode(CursorPayload.self, from: payloadData),
            payload.version == 1,
            payload.scoreBitPattern & 0x7FF0_0000_0000_0000 != 0x7FF0_0000_0000_0000
        else {
            throw LexicalSearchError.invalidCursor
        }
        return payload
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func encodeDate(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
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

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct FTS5LiteralQuery: Sendable {
    let terms: [String]
    let normalizedQuery: String
    let ftsQuery: String?

    init(raw: String) {
        terms = Self.terms(in: raw)
        normalizedQuery = terms.joined(separator: " ")
        ftsQuery =
            terms.isEmpty
            ? nil
            : terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
    }

    func matches(_ value: String?) -> Bool {
        guard let value, !terms.isEmpty else { return false }
        let normalized = Self.comparison(value)
        return terms.contains { normalized.contains(Self.comparison($0)) }
    }

    private static func terms(in raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        func finish() {
            let value = TextSpan.normalize(current)
            if !value.isEmpty, value.contains(where: { $0.isLetter || $0.isNumber }) {
                result.append(value)
            }
            current = ""
        }
        for character in raw {
            if character == "\"" {
                if quoted { finish() }
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                finish()
            } else {
                current.append(character)
            }
        }
        finish()
        return result
    }

    private static func comparison(_ value: String) -> String {
        TextSpan.normalize(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct CursorPayload: Codable, Sendable {
    let version: Int
    let queryFingerprint: String
    let scoreBitPattern: UInt64
    let capturedAt: String
    let frameID: String
    let returnedCount: Int
}

private struct FingerprintInput: Codable, Sendable {
    let normalizedQuery: String
    let intervalStart: String
    let intervalEnd: String
    let bundleIDs: [String]
    let hosts: [String]
    let mode: String
    let policyID: String
    let policyBundleIDs: [String]
    let policyHosts: [String]
    let policyExpiresAt: String
    let policyMaxResults: Int
}

private struct EvidenceKey: Hashable {
    let source: SearchEvidenceSource
    let text: String
}
