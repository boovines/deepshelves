import Foundation

public struct AccessPolicy: Equatable, Sendable, ContractValidatable {
    public let id: UUID
    public let name: String
    public let allowedInterval: DateInterval
    public let allowedBundleIDs: Set<String>
    public let allowedHosts: Set<String>
    public let allowImageResources: Bool
    public let maxResults: Int
    public let expiresAt: Date
    public let createdByUser: Bool

    public init(
        id: UUID,
        name: String,
        allowedInterval: DateInterval,
        allowedBundleIDs: Set<String>,
        allowedHosts: Set<String>,
        allowImageResources: Bool = false,
        maxResults: Int,
        expiresAt: Date,
        createdByUser: Bool
    ) throws {
        self.id = id
        self.name = name
        self.allowedInterval = allowedInterval
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedHosts = allowedHosts
        self.allowImageResources = allowImageResources
        self.maxResults = min(max(maxResults, 1), 100)
        self.expiresAt = expiresAt
        self.createdByUser = createdByUser
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            field: "accessPolicy.name",
            violation: .empty,
            detail: "policy name is required"
        )
        try ContractChecks.validateInterval(
            allowedInterval,
            field: "accessPolicy.allowedInterval",
            maximumDuration: 30 * 24 * 60 * 60
        )
        try ContractChecks.require(
            allowedBundleIDs.allSatisfy { !$0.isEmpty },
            field: "accessPolicy.allowedBundleIDs",
            violation: .empty,
            detail: "bundle identifiers cannot be empty"
        )
        try ContractChecks.require(
            allowedHosts.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() && !$0.contains("@") },
            field: "accessPolicy.allowedHosts",
            violation: .sensitiveURLComponent,
            detail: "hosts must be lowercase hostnames without credentials"
        )
        try ContractChecks.require(
            (1...100).contains(maxResults),
            field: "accessPolicy.maxResults",
            violation: .outOfRange,
            detail: "result bound must be between 1 and 100"
        )
        try ContractChecks.require(
            expiresAt > allowedInterval.end
                && expiresAt.timeIntervalSince(allowedInterval.end) <= 24 * 60 * 60,
            field: "accessPolicy.expiresAt",
            violation: .intervalTooLong,
            detail: "agent policy must expire within 24 hours after its allowed interval ends"
        )
        try ContractChecks.require(
            createdByUser,
            field: "accessPolicy.createdByUser",
            violation: .missingRequiredValue,
            detail: "agent access requires explicit user creation"
        )
    }
}

extension AccessPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case allowedInterval
        case allowedBundleIDs
        case allowedHosts
        case allowImageResources
        case maxResults
        case expiresAt
        case createdByUser
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        allowedInterval = try container.decode(DateInterval.self, forKey: .allowedInterval)
        let bundleIDs = try container.decode([String].self, forKey: .allowedBundleIDs)
        let hosts = try container.decode([String].self, forKey: .allowedHosts)
        guard Set(bundleIDs).count == bundleIDs.count, Set(hosts).count == hosts.count else {
            throw ContractValidationError(
                field: "accessPolicy.allowlists",
                violation: .duplicateValue,
                detail: "serialized allowlists cannot contain duplicates"
            )
        }
        allowedBundleIDs = Set(bundleIDs)
        allowedHosts = Set(hosts)
        allowImageResources = try container.decode(Bool.self, forKey: .allowImageResources)
        maxResults = try container.decode(Int.self, forKey: .maxResults)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        createdByUser = try container.decode(Bool.self, forKey: .createdByUser)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(allowedInterval, forKey: .allowedInterval)
        try container.encode(allowedBundleIDs.sorted(), forKey: .allowedBundleIDs)
        try container.encode(allowedHosts.sorted(), forKey: .allowedHosts)
        try container.encode(allowImageResources, forKey: .allowImageResources)
        try container.encode(maxResults, forKey: .maxResults)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(createdByUser, forKey: .createdByUser)
    }
}

public enum SearchMode: String, Codable, Equatable, Sendable {
    case hybrid
    case textOnly
    case visualOnly
}

public struct SearchCursor: Codable, Equatable, Sendable, ContractValidatable {
    public let token: String

    public init(token: String) throws {
        self.token = token
        try validate()
    }

    public func validate() throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        try ContractChecks.require(
            !token.isEmpty && token.count <= 4_096
                && token.unicodeScalars.allSatisfy(allowed.contains),
            field: "searchCursor.token",
            violation: .outOfRange,
            detail: "cursor must be a bounded opaque URL-safe token"
        )
    }
}

public struct SearchRequest: Equatable, Sendable, ContractValidatable {
    public let query: String
    public let interval: DateInterval?
    public let bundleIDs: Set<String>
    public let hosts: Set<String>
    public let mode: SearchMode
    public let pageSize: Int
    public let cursor: SearchCursor?
    public let accessPolicy: AccessPolicy

    public init(
        query: String,
        interval: DateInterval?,
        bundleIDs: Set<String>,
        hosts: Set<String>,
        mode: SearchMode,
        pageSize: Int,
        cursor: SearchCursor?,
        accessPolicy: AccessPolicy
    ) throws {
        self.query = query
        self.interval = interval
        self.bundleIDs = bundleIDs
        self.hosts = hosts
        self.mode = mode
        self.pageSize = min(max(pageSize, 1), min(100, accessPolicy.maxResults))
        self.cursor = cursor
        self.accessPolicy = accessPolicy
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            query.count <= 2_048,
            field: "searchRequest.query",
            violation: .outOfRange,
            detail: "query exceeds 2048 characters"
        )
        try accessPolicy.validate()
        if let interval {
            try ContractChecks.validateInterval(interval, field: "searchRequest.interval")
            try ContractChecks.require(
                interval.start >= accessPolicy.allowedInterval.start
                    && interval.end <= accessPolicy.allowedInterval.end,
                field: "searchRequest.interval",
                violation: .inconsistent,
                detail: "requested interval exceeds policy"
            )
        }
        try ContractChecks.require(
            bundleIDs.isSubset(of: accessPolicy.allowedBundleIDs),
            field: "searchRequest.bundleIDs",
            violation: .inconsistent,
            detail: "requested bundle identifiers exceed policy"
        )
        try ContractChecks.require(
            hosts.isSubset(of: accessPolicy.allowedHosts)
                && hosts.allSatisfy { $0 == $0.lowercased() },
            field: "searchRequest.hosts",
            violation: .inconsistent,
            detail: "requested hosts exceed policy or are not normalized"
        )
        try ContractChecks.require(
            (1...min(100, accessPolicy.maxResults)).contains(pageSize),
            field: "searchRequest.pageSize",
            violation: .outOfRange,
            detail: "page size exceeds the product or policy bound"
        )
        try cursor?.validate()
    }
}

extension SearchRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case query
        case interval
        case bundleIDs
        case hosts
        case mode
        case pageSize
        case cursor
        case accessPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        interval = try container.decodeIfPresent(DateInterval.self, forKey: .interval)
        let decodedBundleIDs = try container.decode([String].self, forKey: .bundleIDs)
        let decodedHosts = try container.decode([String].self, forKey: .hosts)
        guard Set(decodedBundleIDs).count == decodedBundleIDs.count,
            Set(decodedHosts).count == decodedHosts.count
        else {
            throw ContractValidationError(
                field: "searchRequest.filters",
                violation: .duplicateValue,
                detail: "serialized filters cannot contain duplicates"
            )
        }
        bundleIDs = Set(decodedBundleIDs)
        hosts = Set(decodedHosts)
        mode = try container.decode(SearchMode.self, forKey: .mode)
        pageSize = try container.decode(Int.self, forKey: .pageSize)
        cursor = try container.decodeIfPresent(SearchCursor.self, forKey: .cursor)
        accessPolicy = try container.decode(AccessPolicy.self, forKey: .accessPolicy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encodeIfPresent(interval, forKey: .interval)
        try container.encode(bundleIDs.sorted(), forKey: .bundleIDs)
        try container.encode(hosts.sorted(), forKey: .hosts)
        try container.encode(mode, forKey: .mode)
        try container.encode(pageSize, forKey: .pageSize)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encode(accessPolicy, forKey: .accessPolicy)
    }
}
