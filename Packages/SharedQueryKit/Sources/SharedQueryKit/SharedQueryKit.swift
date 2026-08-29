import Foundation
import MemoryContracts

public enum SharedQueryContract {
    public static let schemaVersion = 1
}

public enum SharedQueryError: Error, Equatable, Sendable {
    case unavailable
    case projectionMismatch
    case policyScopeViolation
}

public struct TimelineQueryRequest: Codable, Equatable, Sendable, ContractValidatable {
    public let interval: DateInterval
    public let bundleIDs: Set<String>
    public let hosts: Set<String>
    public let maximumFrames: Int
    public let accessPolicy: AccessPolicy

    public init(
        interval: DateInterval,
        bundleIDs: Set<String>,
        hosts: Set<String>,
        maximumFrames: Int,
        accessPolicy: AccessPolicy
    ) throws {
        self.interval = interval
        self.bundleIDs = bundleIDs
        self.hosts = hosts
        self.maximumFrames = maximumFrames
        self.accessPolicy = accessPolicy
        try validate()
    }

    public func validate() throws {
        try accessPolicy.validate()
        guard interval.start < interval.end else {
            throw ContractValidationError(
                field: "timelineQueryRequest.interval",
                violation: .invalidInterval,
                detail: "timeline interval must be non-empty and half-open"
            )
        }
        guard interval.start >= accessPolicy.allowedInterval.start,
            interval.end <= accessPolicy.allowedInterval.end
        else {
            throw ContractValidationError(
                field: "timelineQueryRequest.interval",
                violation: .inconsistent,
                detail: "requested interval exceeds policy"
            )
        }
        guard bundleIDs.isSubset(of: accessPolicy.allowedBundleIDs) else {
            throw ContractValidationError(
                field: "timelineQueryRequest.bundleIDs",
                violation: .inconsistent,
                detail: "requested applications exceed policy"
            )
        }
        guard hosts.isSubset(of: accessPolicy.allowedHosts),
            hosts.allSatisfy({ $0 == $0.lowercased() })
        else {
            throw ContractValidationError(
                field: "timelineQueryRequest.hosts",
                violation: .inconsistent,
                detail: "requested sites exceed policy"
            )
        }
        guard (1...min(100, accessPolicy.maxResults)).contains(maximumFrames) else {
            throw ContractValidationError(
                field: "timelineQueryRequest.maximumFrames",
                violation: .outOfRange,
                detail: "timeline result bound exceeds policy"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case interval
        case bundleIDs
        case hosts
        case maximumFrames
        case accessPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interval = try container.decode(DateInterval.self, forKey: .interval)
        let decodedBundleIDs = try container.decode([String].self, forKey: .bundleIDs)
        let decodedHosts = try container.decode([String].self, forKey: .hosts)
        guard Set(decodedBundleIDs).count == decodedBundleIDs.count,
            Set(decodedHosts).count == decodedHosts.count
        else {
            throw ContractValidationError(
                field: "timelineQueryRequest.filters",
                violation: .duplicateValue,
                detail: "serialized filters cannot contain duplicates"
            )
        }
        bundleIDs = Set(decodedBundleIDs)
        hosts = Set(decodedHosts)
        maximumFrames = try container.decode(Int.self, forKey: .maximumFrames)
        accessPolicy = try container.decode(AccessPolicy.self, forKey: .accessPolicy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interval, forKey: .interval)
        try container.encode(bundleIDs.sorted(), forKey: .bundleIDs)
        try container.encode(hosts.sorted(), forKey: .hosts)
        try container.encode(maximumFrames, forKey: .maximumFrames)
        try container.encode(accessPolicy, forKey: .accessPolicy)
    }
}

public struct MomentQueryRequest: Codable, Equatable, Sendable, ContractValidatable {
    public let frameID: UUID
    public let accessPolicy: AccessPolicy

    public init(frameID: UUID, accessPolicy: AccessPolicy) throws {
        self.frameID = frameID
        self.accessPolicy = accessPolicy
        try validate()
    }

    public func validate() throws {
        try accessPolicy.validate()
    }
}

public enum SharedReadRequest: Equatable, Sendable, ContractValidatable {
    case search(SearchRequest)
    case timeline(TimelineQueryRequest)
    case moment(MomentQueryRequest)

    public func validate() throws {
        switch self {
        case .search(let request): try request.validate()
        case .timeline(let request): try request.validate()
        case .moment(let request): try request.validate()
        }
    }
}

public enum SharedReadProjection: Equatable, Sendable, ContractValidatable {
    case search(SearchPage)
    case timeline(TimelineSlice)
    case moment(SearchResult)

    public func validate() throws {
        switch self {
        case .search(let page): try page.validate()
        case .timeline(let slice): try slice.validate()
        case .moment(let result): try result.validate()
        }
    }
}

extension SharedReadProjection: Codable {
    private enum Kind: String, Codable {
        case search
        case timeline
        case moment
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case search
        case timeline
        case moment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == SharedQueryContract.schemaVersion else {
            throw ContractValidationError(
                field: "sharedReadProjection.schemaVersion",
                violation: .unsupportedVersion,
                detail: "unsupported shared query projection version"
            )
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .search:
            self = .search(try container.decode(SearchPage.self, forKey: .search))
        case .timeline:
            self = .timeline(try container.decode(TimelineSlice.self, forKey: .timeline))
        case .moment:
            self = .moment(try container.decode(SearchResult.self, forKey: .moment))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SharedQueryContract.schemaVersion, forKey: .schemaVersion)
        switch self {
        case .search(let page):
            try container.encode(Kind.search, forKey: .kind)
            try container.encode(page, forKey: .search)
        case .timeline(let slice):
            try container.encode(Kind.timeline, forKey: .kind)
            try container.encode(slice, forKey: .timeline)
        case .moment(let result):
            try container.encode(Kind.moment, forKey: .kind)
            try container.encode(result, forKey: .moment)
        }
    }
}

public struct SharedQueryService: Sendable {
    public typealias SearchOperation = @Sendable (SearchRequest) async throws -> SearchPage
    public typealias TimelineOperation =
        @Sendable (TimelineQueryRequest) async throws -> TimelineSlice
    public typealias MomentOperation = @Sendable (MomentQueryRequest) async throws -> SearchResult

    private let searchOperation: SearchOperation
    private let timelineOperation: TimelineOperation
    private let momentOperation: MomentOperation

    public init(
        search: @escaping SearchOperation,
        timeline: @escaping TimelineOperation = { _ in throw SharedQueryError.unavailable },
        moment: @escaping MomentOperation = { _ in throw SharedQueryError.unavailable }
    ) {
        searchOperation = search
        timelineOperation = timeline
        momentOperation = moment
    }

    public func search(_ request: SearchRequest) async throws -> SearchPage {
        try request.validate()
        let page = try await searchOperation(request)
        try page.validate()
        try Self.validate(page: page, request: request)
        return page
    }

    public func execute(_ request: SharedReadRequest) async throws -> SharedReadProjection {
        try request.validate()
        let projection: SharedReadProjection
        switch request {
        case .search(let searchRequest):
            projection = .search(try await search(searchRequest))
        case .timeline(let timelineRequest):
            let slice = try await timelineOperation(timelineRequest)
            try slice.validate()
            guard slice.interval == timelineRequest.interval,
                slice.frames.count <= timelineRequest.maximumFrames
            else {
                throw SharedQueryError.projectionMismatch
            }
            try Self.validate(
                frames: slice.frames,
                bundleIDs: timelineRequest.bundleIDs,
                hosts: timelineRequest.hosts,
                policy: timelineRequest.accessPolicy
            )
            projection = .timeline(slice)
        case .moment(let momentRequest):
            let result = try await momentOperation(momentRequest)
            try result.validate()
            guard result.frameID == momentRequest.frameID else {
                throw SharedQueryError.projectionMismatch
            }
            try Self.validate(
                results: [result],
                bundleIDs: [],
                hosts: [],
                policy: momentRequest.accessPolicy
            )
            projection = .moment(result)
        }
        try projection.validate()
        return projection
    }

    public func canonicalBytes(for request: SharedReadRequest) async throws -> Data {
        try ContractJSON.encode(await execute(request))
    }

    private static func validate(page: SearchPage, request: SearchRequest) throws {
        guard page.results.count <= request.pageSize else {
            throw SharedQueryError.policyScopeViolation
        }
        try validate(
            results: page.results,
            bundleIDs: request.bundleIDs,
            hosts: request.hosts,
            policy: request.accessPolicy
        )
        if let interval = request.interval,
            page.results.contains(where: { !interval.contains($0.capturedAt) })
        {
            throw SharedQueryError.policyScopeViolation
        }
    }

    private static func validate(
        frames: [TimelineFrameSummary],
        bundleIDs: Set<String>,
        hosts: Set<String>,
        policy: AccessPolicy
    ) throws {
        for frame in frames {
            try validate(
                bundleID: frame.foreground.bundleID,
                host: frame.browser?.origin.host,
                requestedBundleIDs: bundleIDs,
                requestedHosts: hosts,
                policy: policy
            )
        }
    }

    private static func validate(
        results: [SearchResult],
        bundleIDs: Set<String>,
        hosts: Set<String>,
        policy: AccessPolicy
    ) throws {
        for result in results {
            try validate(
                bundleID: result.foreground.bundleID,
                host: result.browser?.origin.host,
                requestedBundleIDs: bundleIDs,
                requestedHosts: hosts,
                policy: policy
            )
            guard policy.allowedInterval.contains(result.capturedAt) else {
                throw SharedQueryError.policyScopeViolation
            }
        }
    }

    private static func validate(
        bundleID: String,
        host: String?,
        requestedBundleIDs: Set<String>,
        requestedHosts: Set<String>,
        policy: AccessPolicy
    ) throws {
        guard policy.allowedBundleIDs.contains(bundleID),
            requestedBundleIDs.isEmpty || requestedBundleIDs.contains(bundleID)
        else {
            throw SharedQueryError.policyScopeViolation
        }
        if let host {
            guard policy.allowedHosts.contains(host),
                requestedHosts.isEmpty || requestedHosts.contains(host)
            else {
                throw SharedQueryError.policyScopeViolation
            }
        }
    }
}
