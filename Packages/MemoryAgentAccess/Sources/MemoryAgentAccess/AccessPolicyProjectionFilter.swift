import Foundation
import MemoryContracts
import SharedQueryKit

public enum AccessPolicyProjectionFilter {
    public static func searchPage(_ page: SearchPage, request: SearchRequest) throws
        -> SearchPage
    {
        try request.validate()
        try page.validate()
        let results = page.results.filter { result in
            allows(
                capturedAt: result.capturedAt,
                bundleID: result.foreground.bundleID,
                host: result.browser?.origin.host,
                interval: request.interval,
                bundleIDs: request.bundleIDs,
                hosts: request.hosts,
                policy: request.accessPolicy
            )
        }
        return try SearchPage(
            results: Array(results.prefix(request.pageSize)),
            nextCursor: page.nextCursor
        )
    }

    public static func timeline(_ slice: TimelineSlice, request: TimelineQueryRequest) throws
        -> TimelineSlice
    {
        try request.validate()
        try slice.validate()
        guard slice.interval == request.interval else {
            throw AgentAccessPolicyError.corruptStore
        }
        let frames = slice.frames.filter { frame in
            allows(
                capturedAt: frame.capturedAt,
                bundleID: frame.foreground.bundleID,
                host: frame.browser?.origin.host,
                interval: request.interval,
                bundleIDs: request.bundleIDs,
                hosts: request.hosts,
                policy: request.accessPolicy
            )
        }
        let projectedFrames = Array(frames.prefix(request.maximumFrames))
        let visibleFrameIDs = Set(projectedFrames.map(\.frameID))
        let allowedBundleIDs = request.accessPolicy.allowedBundleIDs
        return try TimelineSlice(
            interval: slice.interval,
            frames: projectedFrames,
            gaps: slice.gaps.filter { gap in
                gap.approvedBundleID.map(allowedBundleIDs.contains) ?? true
            },
            applicationTransitions: slice.applicationTransitions.filter { transition in
                (transition.fromBundleID.map(allowedBundleIDs.contains) ?? true)
                    && (transition.toBundleID.map(allowedBundleIDs.contains) ?? true)
            },
            transcriptMarkers: slice.transcriptMarkers.filter {
                visibleFrameIDs.contains($0.frameID)
            }
        )
    }

    public static func moment(_ result: SearchResult, request: MomentQueryRequest) throws
        -> SearchResult?
    {
        try request.validate()
        try result.validate()
        guard result.frameID == request.frameID,
            allows(
                capturedAt: result.capturedAt,
                bundleID: result.foreground.bundleID,
                host: result.browser?.origin.host,
                interval: request.accessPolicy.allowedInterval,
                bundleIDs: [],
                hosts: [],
                policy: request.accessPolicy
            )
        else {
            return nil
        }
        return result
    }

    private static func allows(
        capturedAt: Date,
        bundleID: String,
        host: String?,
        interval: DateInterval?,
        bundleIDs: Set<String>,
        hosts: Set<String>,
        policy: AccessPolicy
    ) -> Bool {
        guard policy.allowedInterval.contains(capturedAt),
            interval.map({ $0.contains(capturedAt) }) ?? true,
            policy.allowedBundleIDs.contains(bundleID),
            bundleIDs.isEmpty || bundleIDs.contains(bundleID)
        else {
            return false
        }
        guard let host else { return true }
        return policy.allowedHosts.contains(host)
            && (hosts.isEmpty || hosts.contains(host))
    }
}
