import Foundation
import MemoryContracts
import MemoryStore

public enum VisualSearchError: Error, Equatable, Sendable {
    case invalidModelIdentity
    case unsupportedMode
    case cursorUnavailable
    case expiredAccessPolicy
    case modelUnavailable
    case invalidEmbedding
    case invalidStoredProjection
}

public struct VisualQueryEmbeddingProvider: Sendable {
    public let modelHash: Data
    public let dimension: Int
    private let operation: @Sendable (String) async throws -> [Float]

    public init(
        modelHash: Data,
        dimension: Int,
        operation: @escaping @Sendable (String) async throws -> [Float]
    ) throws {
        guard modelHash.count == 32, dimension > 0 else {
            throw VisualSearchError.invalidModelIdentity
        }
        self.modelHash = modelHash
        self.dimension = dimension
        self.operation = operation
    }

    public func embed(query: String) async throws -> [Float] {
        try await operation(query)
    }
}

public final class VisualSearchEngine: @unchecked Sendable, SearchEngine {
    private let vectorStore: ArchiveVectorStore
    private let projectionStore: ArchiveVisualSearchStore
    private let model: ArchiveVectorModelIdentity
    private let embedder: VisualQueryEmbeddingProvider
    private let searcher: ExactVisualVectorSearcher
    private let now: @Sendable () -> Date

    public init(
        database: ArchiveDatabase,
        model: ArchiveVectorModelIdentity,
        embedder: VisualQueryEmbeddingProvider,
        searcher: ExactVisualVectorSearcher = ExactVisualVectorSearcher(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard embedder.modelHash == model.modelHash, embedder.dimension == model.dimension else {
            throw VisualSearchError.invalidModelIdentity
        }
        vectorStore = try ArchiveVectorStore(database: database)
        projectionStore = ArchiveVisualSearchStore(database: database)
        self.model = model
        self.embedder = embedder
        self.searcher = searcher
        self.now = now
    }

    public func search(_ request: SearchRequest) async throws -> SearchPage {
        try Task.checkCancellation()
        try request.validate()
        guard request.mode == .visualOnly else { throw VisualSearchError.unsupportedMode }
        guard request.cursor == nil else { throw VisualSearchError.cursorUnavailable }
        try requireCurrent(request.accessPolicy)
        guard !request.accessPolicy.allowedBundleIDs.isEmpty else {
            return try SearchPage(results: [], nextCursor: nil)
        }
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try SearchPage(results: [], nextCursor: nil) }

        let interval = request.interval ?? request.accessPolicy.allowedInterval
        let bundleIdentifiers =
            request.bundleIDs.isEmpty
            ? request.accessPolicy.allowedBundleIDs
            : request.bundleIDs
        let filter = ArchiveVectorScanFilter(
            capturedAt: interval.start..<interval.end,
            bundleIdentifiers: bundleIdentifiers,
            allowedHosts: request.accessPolicy.allowedHosts,
            hosts: request.hosts
        )
        let snapshot = try vectorStore.scanSnapshot(model: model, filter: filter)
        try Task.checkCancellation()
        try requireCurrent(request.accessPolicy)
        guard !snapshot.candidates.isEmpty else {
            return try SearchPage(results: [], nextCursor: nil)
        }

        let rawEmbedding: [Float]
        do {
            rawEmbedding = try await embedder.embed(query: query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VisualSearchError.modelUnavailable
        }
        let queryVector = try normalize(rawEmbedding)
        try Task.checkCancellation()
        try requireCurrent(request.accessPolicy)
        let matches = try await searcher.search(
            query: queryVector,
            snapshot: snapshot,
            limit: request.pageSize
        )
        try Task.checkCancellation()
        try requireCurrent(request.accessPolicy)
        let projections = try projectionStore.projections(
            frameIDs: matches.map(\.frameID),
            modelHash: model.modelHash,
            filter: filter
        )
        try Task.checkCancellation()
        try requireCurrent(request.accessPolicy)

        let results = try matches.enumerated().compactMap { index, match -> SearchResult? in
            guard let projection = projections[match.frameID],
                projection.capturedAt == match.capturedAt
            else {
                return nil
            }
            let score = max(0, min(1, (Double(match.score) + 1) / 2))
            let mediaLocator: ContentLocator
            let thumbnailLocator: ContentLocator?
            if request.accessPolicy.allowImageResources {
                mediaLocator = .archiveRelativePath(projection.mediaPath.rawValue)
                thumbnailLocator = projection.thumbnailPath.map {
                    .archiveRelativePath($0.rawValue)
                }
            } else {
                mediaLocator = .opaqueResourceID(
                    "visual-redacted-\(match.frameID.uuidString.lowercased())"
                )
                thumbnailLocator = nil
            }
            return try SearchResult(
                frameID: match.frameID,
                capturedAt: match.capturedAt,
                foreground: projection.foreground,
                browser: projection.browser,
                thumbnailLocator: thumbnailLocator,
                mediaLocator: mediaLocator,
                evidence: [SearchEvidence(source: .visual, matchedText: nil, score: score)],
                textRank: nil,
                visualRank: index + 1,
                fusedScore: score
            )
        }
        try Task.checkCancellation()
        try requireCurrent(request.accessPolicy)
        return try SearchPage(results: results, nextCursor: nil)
    }

    private func requireCurrent(_ policy: AccessPolicy) throws {
        guard now() < policy.expiresAt else { throw VisualSearchError.expiredAccessPolicy }
    }

    private func normalize(_ values: [Float]) throws -> [Float] {
        guard values.count == model.dimension, values.allSatisfy(\.isFinite) else {
            throw VisualSearchError.invalidEmbedding
        }
        var squaredNorm = 0.0
        for value in values { squaredNorm += Double(value) * Double(value) }
        guard squaredNorm.isFinite, squaredNorm > 0 else {
            throw VisualSearchError.invalidEmbedding
        }
        let norm = sqrt(squaredNorm)
        let normalized = values.map { Float(Double($0) / norm) }
        guard normalized.allSatisfy(\.isFinite) else {
            throw VisualSearchError.invalidEmbedding
        }
        return normalized
    }
}

public final class LocalSearchEngine: @unchecked Sendable, SearchEngine {
    private let lexical: any SearchEngine
    private let visual: (any SearchEngine)?

    public init(lexical: any SearchEngine, visual: (any SearchEngine)?) {
        self.lexical = lexical
        self.visual = visual
    }

    public func search(_ request: SearchRequest) async throws -> SearchPage {
        switch request.mode {
        case .textOnly, .hybrid:
            return try await lexical.search(request)
        case .visualOnly:
            guard let visual else { throw LexicalSearchError.visualSearchUnavailable }
            return try await visual.search(request)
        }
    }
}
