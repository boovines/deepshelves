import Foundation

public enum S7OfflineJourneyStage: String, Codable, CaseIterable, Sendable {
    case firstLaunch
    case onboarding
    case capture
    case search
    case visualInference
    case deletion
    case export
    case cli
    case mcp

    public static let requiredOrder: [Self] = [
        .firstLaunch,
        .onboarding,
        .capture,
        .search,
        .visualInference,
        .deletion,
        .export,
        .cli,
        .mcp,
    ]
}

public enum S7OfflineJourneyError: Error, Equatable, Sendable {
    case unexpectedStage(expected: S7OfflineJourneyStage?, received: S7OfflineJourneyStage)
}

public struct S7OfflineJourneyTracker: Codable, Equatable, Sendable {
    public private(set) var completedStages: [S7OfflineJourneyStage]

    public init(completedStages: [S7OfflineJourneyStage] = []) {
        self.completedStages = completedStages
    }

    public var isComplete: Bool {
        completedStages == S7OfflineJourneyStage.requiredOrder
    }

    public mutating func complete(_ stage: S7OfflineJourneyStage) throws {
        let expected = S7OfflineJourneyStage.requiredOrder.dropFirst(completedStages.count).first
        guard expected == stage else {
            throw S7OfflineJourneyError.unexpectedStage(expected: expected, received: stage)
        }
        completedStages.append(stage)
    }
}

public struct S7ProvenanceRecord: Codable, Equatable, Sendable {
    public let path: String
    public let source: String
    public let version: String
    public let license: String
    public let sha256: String
    public let updateProcedure: String

    public init(
        path: String,
        source: String,
        version: String,
        license: String,
        sha256: String,
        updateProcedure: String
    ) {
        self.path = path
        self.source = source
        self.version = version
        self.license = license
        self.sha256 = sha256
        self.updateProcedure = updateProcedure
    }

    public var isComplete: Bool {
        !path.isEmpty &&
            !source.isEmpty &&
            !version.isEmpty &&
            !license.isEmpty &&
            sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil &&
            !updateProcedure.isEmpty
    }
}
