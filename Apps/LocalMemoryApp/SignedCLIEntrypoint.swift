import Darwin
import Foundation
import MemoryAgentAccess
import MemoryContracts
import MemorySearch
import MemoryStore
import SharedQueryKit

enum SignedCLIEntrypoint {
    static func launchIfRequested(arguments: [String], database: ArchiveDatabase?) {
        guard let modeIndex = arguments.firstIndex(of: "--cli") else { return }
        let commandArguments = Array(arguments.dropFirst(modeIndex + 1))
        Task.detached {
            let result = await LocalMemoryCLIExecutor.execute(
                arguments: commandArguments,
                backend: makeBackend(database: database)
            )
            if !result.standardOutput.isEmpty {
                FileHandle.standardOutput.write(result.standardOutput)
            }
            if !result.standardError.isEmpty {
                FileHandle.standardError.write(result.standardError)
            }
            Darwin.exit(result.exitCode)
        }
    }

    static func makeBackend(database: ArchiveDatabase?) -> LocalMemoryCLIBackend {
        guard let database, let root = database.paths?.root else {
            return unavailableBackend()
        }
        let policyStore = AccessPolicyStore(
            fileURL: root.appending(path: "agent-access/policies-v1.json")
        )
        return LocalMemoryCLIBackend(
            status: {
                do {
                    let capability = try await policyStore.localCapability()
                    let policies = try await policyStore.list(capability: capability)
                    return CLIStatusProjection(
                        recordingState: "inactive",
                        archiveReadable: true,
                        policyCount: policies.count
                    )
                } catch {
                    throw map(error)
                }
            },
            search: { input in
                try await withPolicy(input.policyID, store: policyStore) { policy, capability in
                    let request = try SearchRequest(
                        query: input.query,
                        interval: nil,
                        bundleIDs: [],
                        hosts: [],
                        mode: .textOnly,
                        pageSize: min(input.limit, policy.maxResults),
                        cursor: try input.cursor.map(SearchCursor.init(token:)),
                        accessPolicy: policy
                    )
                    let engine = try LexicalSearchEngine(
                        database: database,
                        cursorSigningKey: capability
                    )
                    let page = try await engine.search(request)
                    let filtered = try AccessPolicyProjectionFilter.searchPage(
                        page,
                        request: request
                    )
                    return CLISearchProjection(
                        results: filtered.results.map(project),
                        nextCursor: filtered.nextCursor?.token
                    )
                }
            },
            timeline: { input in
                try await withPolicy(input.policyID, store: policyStore) { policy, _ in
                    guard input.interval.start >= policy.allowedInterval.start,
                        input.interval.end <= policy.allowedInterval.end
                    else {
                        throw LocalMemoryCLIError.policyDenied
                    }
                    let query = ArchiveTimelineQuery(database: database)
                    var cursor = input.interval.start
                    var frames: [CLIResultProjection] = []
                    var gaps: [CLITimelineGapProjection] = []
                    while cursor < input.interval.end, frames.count < policy.maxResults {
                        try Task.checkCancellation()
                        let page = try query.page(
                            TimelinePageRequest(
                                interval: input.interval,
                                cursor: cursor,
                                zoom: .calendarDay,
                                calendarTimeZone: .gmt
                            )
                        )
                        let request = try TimelineQueryRequest(
                            interval: page.slice.interval,
                            bundleIDs: [],
                            hosts: [],
                            maximumFrames: max(1, policy.maxResults - frames.count),
                            accessPolicy: policy
                        )
                        let filtered = try AccessPolicyProjectionFilter.timeline(
                            page.slice,
                            request: request
                        )
                        frames.append(contentsOf: filtered.frames.map(project))
                        gaps.append(contentsOf: filtered.gaps.map(project))
                        guard let next = page.nextCursor?.start, next > cursor else { break }
                        cursor = next
                    }
                    return CLITimelineProjection(
                        frames: Array(frames.prefix(policy.maxResults)),
                        gaps: gaps
                    )
                }
            },
            moment: { input in
                try await withPolicy(input.policyID, store: policyStore) { policy, _ in
                    guard
                        let result = try findMoment(
                            input.frameID,
                            policy: policy,
                            database: database
                        )
                    else {
                        throw LocalMemoryCLIError.notFound
                    }
                    return CLIMomentProjection(result: project(result))
                }
            },
            imageResource: { input in
                try await withPolicy(input.policyID, store: policyStore) { policy, _ in
                    guard policy.allowImageResources,
                        let frameID = frameID(fromResourceID: input.resourceID),
                        try findMoment(frameID, policy: policy, database: database) != nil
                    else {
                        throw LocalMemoryCLIError.policyDenied
                    }
                    let source = try ArchiveMomentSourceStore(database: database).readySource(
                        frameID: frameID
                    )
                    return CLIImageResourceProjection(
                        resourceID: input.resourceID,
                        mediaType: "image/heic",
                        byteCount: source.mediaByteCount
                    )
                }
            }
        )
    }

    private static func unavailableBackend() -> LocalMemoryCLIBackend {
        LocalMemoryCLIBackend(
            status: { throw LocalMemoryCLIError.unavailable },
            search: { _ in throw LocalMemoryCLIError.unavailable },
            timeline: { _ in throw LocalMemoryCLIError.unavailable },
            moment: { _ in throw LocalMemoryCLIError.unavailable },
            imageResource: { _ in throw LocalMemoryCLIError.unavailable }
        )
    }

    private static func withPolicy<Result: Sendable>(
        _ id: UUID,
        store: AccessPolicyStore,
        operation: @escaping @Sendable (AccessPolicy, Data) async throws -> Result
    ) async throws -> Result {
        do {
            let capability = try await store.localCapability()
            return try await store.withAuthorizedPolicy(id: id, capability: capability) { policy in
                try await operation(policy, capability)
            }
        } catch {
            throw map(error)
        }
    }

    private static func findMoment(
        _ frameID: UUID,
        policy: AccessPolicy,
        database: ArchiveDatabase
    ) throws -> SearchResult? {
        let query = ArchiveTimelineQuery(database: database)
        var cursor = policy.allowedInterval.start
        while cursor < policy.allowedInterval.end {
            let page = try query.page(
                TimelinePageRequest(
                    interval: policy.allowedInterval,
                    cursor: cursor,
                    zoom: .calendarDay,
                    calendarTimeZone: .gmt
                )
            )
            if let frame = page.slice.frames.first(where: { $0.frameID == frameID }) {
                let result = try SearchResult(
                    frameID: frame.frameID,
                    capturedAt: frame.capturedAt,
                    foreground: frame.foreground,
                    browser: frame.browser,
                    thumbnailLocator: policy.allowImageResources ? frame.thumbnailLocator : nil,
                    mediaLocator: .opaqueResourceID(resourceID(for: frame.frameID)),
                    evidence: [
                        SearchEvidence(
                            source: .application,
                            matchedText: frame.foreground.applicationName,
                            score: 0
                        )
                    ],
                    textRank: nil,
                    visualRank: nil,
                    fusedScore: 0
                )
                return try AccessPolicyProjectionFilter.moment(
                    result,
                    request: MomentQueryRequest(frameID: frameID, accessPolicy: policy)
                )
            }
            guard let next = page.nextCursor?.start, next > cursor else { break }
            cursor = next
        }
        return nil
    }

    private static func project(_ result: SearchResult) -> CLIResultProjection {
        let evidence = result.evidence.max { $0.score < $1.score }
        return CLIResultProjection(
            frameID: result.frameID,
            capturedAt: result.capturedAt,
            application: result.foreground.applicationName,
            bundleID: result.foreground.bundleID,
            host: result.browser?.origin.host,
            excerpt: evidence?.matchedText,
            evidenceSource: evidence?.source.rawValue ?? "application"
        )
    }

    private static func project(_ frame: TimelineFrameSummary) -> CLIResultProjection {
        CLIResultProjection(
            frameID: frame.frameID,
            capturedAt: frame.capturedAt,
            application: frame.foreground.applicationName,
            bundleID: frame.foreground.bundleID,
            host: frame.browser?.origin.host,
            excerpt: nil,
            evidenceSource: "application"
        )
    }

    private static func project(_ gap: RecordingGap) -> CLITimelineGapProjection {
        CLITimelineGapProjection(
            startedAt: gap.startedAt,
            endedAt: gap.endedAt,
            reason: gap.reason.rawValue
        )
    }

    private static func resourceID(for frameID: UUID) -> String {
        "frame-\(frameID.uuidString.lowercased())"
    }

    private static func frameID(fromResourceID resourceID: String) -> UUID? {
        guard resourceID.hasPrefix("frame-") else { return nil }
        return UUID(uuidString: String(resourceID.dropFirst("frame-".count)))
    }

    private static func map(_ error: Error) -> LocalMemoryCLIError {
        if let error = error as? LocalMemoryCLIError { return error }
        if error is CancellationError { return .cancelled }
        switch error as? AgentAccessPolicyError {
        case .notFound: return .notFound
        case .revoked: return .revoked
        case .expired: return .expired
        case .invalidCapability: return .policyDenied
        case .corruptStore, .unsafePath: return .integrityFailure
        case .duplicatePolicy, .none: return .unavailable
        }
    }
}
