import Foundation

public struct ProducerVersion: Codable, Equatable, Sendable, ContractValidatable {
    public let name: String
    public let semanticVersion: String
    public let modelHash: Data

    public init(name: String, semanticVersion: String, modelHash: Data) throws {
        self.name = name
        self.semanticVersion = semanticVersion
        self.modelHash = modelHash
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            field: "producer.name",
            violation: .empty,
            detail: "producer name is required"
        )
        let semanticVersionRange = semanticVersion.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#,
            options: .regularExpression
        )
        try ContractChecks.require(
            semanticVersionRange != nil,
            field: "producer.semanticVersion",
            violation: .inconsistent,
            detail: "producer version must use semantic version syntax"
        )
        try ContractChecks.require(
            modelHash.count == 32,
            field: "producer.modelHash",
            violation: .outOfRange,
            detail: "producer model hash must contain 32 bytes"
        )
    }
}

public enum EnrichmentArtifactKind: String, Codable, Equatable, Sendable {
    case mergedText
    case thumbnail
    case visualVector
    case transcriptSegment
}

public enum ArtifactState: String, Codable, Equatable, Sendable {
    case ready
    case stale
    case failed
    case deleted
}

public enum PayloadLocator: Equatable, Sendable, ContractValidatable {
    case inlineDatabaseRow(rowID: String)
    case relativeFileOffset(path: String, byteOffset: Int64, byteLength: Int)

    public func validate() throws {
        switch self {
        case .inlineDatabaseRow(let rowID):
            try ContractChecks.require(
                !rowID.isEmpty,
                field: "payloadLocator.rowID",
                violation: .empty,
                detail: "inline row identifier is required"
            )
        case .relativeFileOffset(let path, let byteOffset, let byteLength):
            try ContractChecks.validateRelativePath(path, field: "payloadLocator.path")
            try ContractChecks.require(
                byteOffset >= 0 && byteLength > 0,
                field: "payloadLocator.offset",
                violation: .outOfRange,
                detail: "file offset must be non-negative and length positive"
            )
        }
    }
}

extension PayloadLocator: Codable {
    private enum Kind: String, Codable {
        case inlineDatabaseRow
        case relativeFileOffset
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case rowID
        case path
        case byteOffset
        case byteLength
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .inlineDatabaseRow:
            self = .inlineDatabaseRow(rowID: try container.decode(String.self, forKey: .rowID))
        case .relativeFileOffset:
            self = .relativeFileOffset(
                path: try container.decode(String.self, forKey: .path),
                byteOffset: try container.decode(Int64.self, forKey: .byteOffset),
                byteLength: try container.decode(Int.self, forKey: .byteLength)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inlineDatabaseRow(let rowID):
            try container.encode(Kind.inlineDatabaseRow, forKey: .kind)
            try container.encode(rowID, forKey: .rowID)
        case .relativeFileOffset(let path, let byteOffset, let byteLength):
            try container.encode(Kind.relativeFileOffset, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(byteOffset, forKey: .byteOffset)
            try container.encode(byteLength, forKey: .byteLength)
        }
    }
}

public struct EnrichmentArtifact: Codable, Equatable, Sendable, ContractValidatable {
    public let id: UUID
    public let frameID: UUID
    public let kind: EnrichmentArtifactKind
    public let producer: ProducerVersion
    public let createdAt: Date
    public let payloadLocator: PayloadLocator
    public let contentHash: Data
    public let state: ArtifactState

    public init(
        id: UUID,
        frameID: UUID,
        kind: EnrichmentArtifactKind,
        producer: ProducerVersion,
        createdAt: Date,
        payloadLocator: PayloadLocator,
        contentHash: Data,
        state: ArtifactState
    ) throws {
        self.id = id
        self.frameID = frameID
        self.kind = kind
        self.producer = producer
        self.createdAt = createdAt
        self.payloadLocator = payloadLocator
        self.contentHash = contentHash
        self.state = state
        try validate()
    }

    public func validate() throws {
        try producer.validate()
        try payloadLocator.validate()
        if state == .ready || !contentHash.isEmpty {
            try ContractChecks.require(
                contentHash.count == 32,
                field: "enrichmentArtifact.contentHash",
                violation: .outOfRange,
                detail: "content hash must contain 32 bytes"
            )
        }
    }
}
