import CryptoKit
import Darwin
import Foundation
import MemoryContracts

public enum AgentAccessPolicyError: Error, Equatable, Sendable {
    case invalidCapability
    case notFound
    case revoked
    case expired
    case duplicatePolicy
    case corruptStore
    case unsafePath
}

public struct AccessPolicyDraft: Equatable, Sendable {
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
        id: UUID = UUID(),
        name: String,
        allowedInterval: DateInterval,
        allowedBundleIDs: Set<String>,
        allowedHosts: Set<String>,
        allowImageResources: Bool,
        maxResults: Int,
        expiresAt: Date,
        createdByUser: Bool
    ) throws {
        guard (1...100).contains(maxResults) else {
            throw ContractValidationError(
                field: "accessPolicyDraft.maxResults",
                violation: .outOfRange,
                detail: "result bound must be between 1 and 100"
            )
        }
        self.id = id
        self.name = name
        self.allowedInterval = allowedInterval
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedHosts = allowedHosts
        self.allowImageResources = allowImageResources
        self.maxResults = maxResults
        self.expiresAt = expiresAt
        self.createdByUser = createdByUser
        _ = try makePolicy()
    }

    fileprivate func makePolicy() throws -> AccessPolicy {
        try AccessPolicy(
            id: id,
            name: name,
            allowedInterval: allowedInterval,
            allowedBundleIDs: allowedBundleIDs,
            allowedHosts: allowedHosts,
            allowImageResources: allowImageResources,
            maxResults: maxResults,
            expiresAt: expiresAt,
            createdByUser: createdByUser
        )
    }
}

public actor AccessPolicyStore {
    private let fileURL: URL
    private let capabilityKeyStore: any AgentCapabilityKeyStoring
    private let now: @Sendable () -> Date
    private var cachedState: PersistedPolicyState?

    public init(
        fileURL: URL,
        capabilityKeyStore: any AgentCapabilityKeyStoring = SystemAgentCapabilityKeyStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.capabilityKeyStore = capabilityKeyStore
        self.now = now
    }

    public func localCapability() throws -> Data {
        try capabilityKeyStore.loadOrCreate()
    }

    public func create(_ draft: AccessPolicyDraft) throws -> AccessPolicy {
        let key = try capabilityKeyStore.loadOrCreate()
        var state = try loadState(key: key)
        let policy = try draft.makePolicy()
        guard now() < policy.expiresAt else { throw AgentAccessPolicyError.expired }
        guard !state.active.contains(where: { $0.id == policy.id }),
            !state.revokedIDs.contains(policy.id)
        else {
            throw AgentAccessPolicyError.duplicatePolicy
        }
        state.active.append(policy)
        state.revision += 1
        try persist(state, key: key)
        cachedState = state
        return policy
    }

    public func list(capability: Data) throws -> [AccessPolicy] {
        let key = try requireCapability(capability)
        let state = try loadState(key: key)
        return state.active
            .filter { now() < $0.expiresAt }
            .sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
    }

    public func policy(id: UUID, capability: Data) throws -> AccessPolicy {
        let key = try requireCapability(capability)
        return try currentPolicy(id: id, state: loadState(key: key))
    }

    public func revoke(id: UUID, capability: Data) throws {
        let key = try requireCapability(capability)
        var state = try loadState(key: key)
        guard let index = state.active.firstIndex(where: { $0.id == id }) else {
            if state.revokedIDs.contains(id) { throw AgentAccessPolicyError.revoked }
            throw AgentAccessPolicyError.notFound
        }
        state.active.remove(at: index)
        state.revokedIDs.append(id)
        state.revision += 1
        try persist(state, key: key)
        cachedState = state
    }

    public func withAuthorizedPolicy<Result: Sendable>(
        id: UUID,
        capability: Data,
        operation: @escaping @Sendable (AccessPolicy) async throws -> Result
    ) async throws -> Result {
        let key = try requireCapability(capability)
        let policy = try currentPolicy(id: id, state: loadState(key: key))
        let result = try await operation(policy)
        let finalPolicy = try currentPolicy(id: id, state: loadState(key: key, refresh: true))
        guard finalPolicy == policy else { throw AgentAccessPolicyError.revoked }
        return result
    }

    private func currentPolicy(id: UUID, state: PersistedPolicyState) throws -> AccessPolicy {
        guard let policy = state.active.first(where: { $0.id == id }) else {
            if state.revokedIDs.contains(id) { throw AgentAccessPolicyError.revoked }
            throw AgentAccessPolicyError.notFound
        }
        guard now() < policy.expiresAt else { throw AgentAccessPolicyError.expired }
        return policy
    }

    private func requireCapability(_ presented: Data) throws -> Data {
        let expected = try capabilityKeyStore.loadOrCreate()
        guard Self.constantTimeEqual(presented, expected) else {
            throw AgentAccessPolicyError.invalidCapability
        }
        return expected
    }

    private func loadState(key: Data, refresh: Bool = false) throws -> PersistedPolicyState {
        if !refresh, let cachedState { return cachedState }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = PersistedPolicyState.empty
            cachedState = empty
            return empty
        }
        try requireSafeRegularFile(fileURL)
        let envelope: SignedPolicyEnvelope
        do {
            envelope = try JSONDecoder().decode(
                SignedPolicyEnvelope.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw AgentAccessPolicyError.corruptStore
        }
        let expected = Self.authenticationCode(for: envelope.payload, key: key)
        guard Self.constantTimeEqual(envelope.authenticationCode, expected) else {
            throw AgentAccessPolicyError.corruptStore
        }
        do {
            let state = try ContractJSON.decode(PersistedPolicyState.self, from: envelope.payload)
            cachedState = state
            return state
        } catch {
            throw AgentAccessPolicyError.corruptStore
        }
    }

    private func persist(_ state: PersistedPolicyState, key: Data) throws {
        try state.validate()
        let directory = fileURL.deletingLastPathComponent()
        try prepareOwnerOnlyDirectory(directory)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try requireSafeRegularFile(fileURL)
        }
        let payload = try ContractJSON.encode(state)
        let envelope = SignedPolicyEnvelope(
            payload: payload,
            authenticationCode: Self.authenticationCode(for: payload, key: key)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
        guard chmod(fileURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw AgentAccessPolicyError.unsafePath
        }
    }

    private func prepareOwnerOnlyDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AgentAccessPolicyError.unsafePath
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        guard chmod(directory.path, S_IRWXU) == 0 else {
            throw AgentAccessPolicyError.unsafePath
        }
    }

    private func requireSafeRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AgentAccessPolicyError.unsafePath
        }
    }

    private static func authenticationCode(for payload: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private struct SignedPolicyEnvelope: Codable {
    let payload: Data
    let authenticationCode: Data
}

private struct PersistedPolicyState: Codable, ContractValidatable {
    let schemaVersion: Int
    var revision: Int
    var active: [AccessPolicy]
    var revokedIDs: [UUID]

    static let empty = PersistedPolicyState(
        schemaVersion: 1,
        revision: 0,
        active: [],
        revokedIDs: []
    )

    func validate() throws {
        guard schemaVersion == 1, revision >= 0 else {
            throw AgentAccessPolicyError.corruptStore
        }
        let activeIDs = active.map(\.id)
        guard Set(activeIDs).count == activeIDs.count,
            Set(revokedIDs).count == revokedIDs.count,
            Set(activeIDs).isDisjoint(with: revokedIDs)
        else {
            throw AgentAccessPolicyError.corruptStore
        }
        for policy in active {
            try policy.validate()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case active
        case revokedIDs
    }

    init(
        schemaVersion: Int,
        revision: Int,
        active: [AccessPolicy],
        revokedIDs: [UUID]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.active = active
        self.revokedIDs = revokedIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        active = try container.decode([AccessPolicy].self, forKey: .active)
        revokedIDs = try container.decode([UUID].self, forKey: .revokedIDs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(
            active.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() },
            forKey: .active
        )
        try container.encode(
            revokedIDs.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() },
            forKey: .revokedIDs
        )
    }
}
