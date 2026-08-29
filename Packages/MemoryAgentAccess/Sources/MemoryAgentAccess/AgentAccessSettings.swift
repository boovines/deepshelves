import CryptoKit
import Foundation

public enum AgentAccessSettingsError: Error, Equatable, Sendable {
    case invalidProposal
    case reviewMismatch
}

public enum AgentAccessHistoryWindow: String, CaseIterable, Sendable {
    case lastTwentyFourHours
    case lastSevenDays
    case lastThirtyDays

    public var seconds: TimeInterval {
        switch self {
        case .lastTwentyFourHours: 24 * 60 * 60
        case .lastSevenDays: 7 * 24 * 60 * 60
        case .lastThirtyDays: 30 * 24 * 60 * 60
        }
    }

    public var explanation: String {
        switch self {
        case .lastTwentyFourHours: "the last 24 hours"
        case .lastSevenDays: "the last 7 days"
        case .lastThirtyDays: "the last 30 days"
        }
    }
}

public enum AgentAccessSessionDuration: String, CaseIterable, Sendable {
    case oneHour
    case eightHours
    case twentyFourHours

    public var seconds: TimeInterval {
        switch self {
        case .oneHour: 60 * 60
        case .eightHours: 8 * 60 * 60
        case .twentyFourHours: 24 * 60 * 60
        }
    }

    public var explanation: String {
        switch self {
        case .oneHour: "1 hour"
        case .eightHours: "8 hours"
        case .twentyFourHours: "24 hours"
        }
    }
}

public struct AgentAccessPolicyProposal: Equatable, Sendable {
    public let name: String
    public let historyWindow: AgentAccessHistoryWindow
    public let allowedBundleIDs: Set<String>
    public let allowedHosts: Set<String>
    public let allowImageResources: Bool
    public let maxResults: Int
    public let sessionDuration: AgentAccessSessionDuration

    public init(
        name: String,
        historyWindow: AgentAccessHistoryWindow,
        allowedBundleIDs: Set<String>,
        allowedHosts: Set<String>,
        allowImageResources: Bool,
        maxResults: Int,
        sessionDuration: AgentAccessSessionDuration
    ) {
        self.name = name
        self.historyWindow = historyWindow
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedHosts = allowedHosts
        self.allowImageResources = allowImageResources
        self.maxResults = maxResults
        self.sessionDuration = sessionDuration
    }

    public func review(now: Date = Date()) throws -> AgentAccessPolicyReview {
        guard (1...100).contains(maxResults), now.timeIntervalSince1970.isFinite else {
            throw AgentAccessSettingsError.invalidProposal
        }
        let draft = try AccessPolicyDraft(
            name: name,
            allowedInterval: DateInterval(
                start: now.addingTimeInterval(-historyWindow.seconds),
                end: now
            ),
            allowedBundleIDs: allowedBundleIDs,
            allowedHosts: allowedHosts,
            allowImageResources: allowImageResources,
            maxResults: maxResults,
            expiresAt: now.addingTimeInterval(sessionDuration.seconds),
            createdByUser: true
        )
        let scope: String
        if allowedBundleIDs.isEmpty, allowedHosts.isEmpty {
            scope = "No applications or sites are approved, so no captured content will be visible."
        } else {
            let applications = allowedBundleIDs.sorted().joined(separator: ", ")
            let hosts = allowedHosts.sorted().joined(separator: ", ")
            scope =
                "Applications: \(applications.isEmpty ? "none" : applications). Sites: \(hosts.isEmpty ? "none" : hosts)."
        }
        let explanation = [
            "History is limited to \(historyWindow.explanation).",
            scope,
            allowImageResources
                ? "Specific moment images may be requested separately."
                : "Text and metadata only; images are denied.",
            "Each query returns at most \(maxResults) results.",
            "This approval expires in \(sessionDuration.explanation).",
        ].joined(separator: "\n")
        let token = Self.reviewToken(draft: draft, explanation: explanation)
        return AgentAccessPolicyReview(
            draft: draft,
            explanation: explanation,
            confirmationToken: token
        )
    }

    private static func reviewToken(draft: AccessPolicyDraft, explanation: String) -> String {
        let input = [
            draft.id.uuidString.lowercased(),
            draft.name,
            draft.allowedInterval.start.ISO8601Format(),
            draft.allowedInterval.end.ISO8601Format(),
            draft.allowedBundleIDs.sorted().joined(separator: ","),
            draft.allowedHosts.sorted().joined(separator: ","),
            String(draft.allowImageResources),
            String(draft.maxResults),
            draft.expiresAt.ISO8601Format(),
            explanation,
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AgentAccessPolicyReview: Equatable, Identifiable, Sendable {
    public let draft: AccessPolicyDraft
    public let explanation: String
    public let confirmationToken: String

    public var id: String { confirmationToken }

    public func approve(confirmationToken: String) throws -> AccessPolicyDraft {
        guard confirmationToken == self.confirmationToken else {
            throw AgentAccessSettingsError.reviewMismatch
        }
        return draft
    }
}

public enum AgentHelperDiagnosticState: String, Equatable, Sendable {
    case ready
    case applicationExecutableMissing
}

public struct AgentHelperDiagnostics: Equatable, Sendable {
    public let state: AgentHelperDiagnosticState
    public let applicationExecutablePath: String
    public let mcpConfiguration: String

    public static func inspect(
        applicationExecutableURL: URL,
        isExecutable: (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) -> Self {
        let configuration = MCPConfiguration(
            mcpServers: [
                "local-memory": MCPConfiguration.Server(
                    command: applicationExecutableURL.path,
                    args: ["--mcp"]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(configuration)) ?? Data("{}".utf8)
        return Self(
            state: isExecutable(applicationExecutableURL) ? .ready : .applicationExecutableMissing,
            applicationExecutablePath: applicationExecutableURL.path,
            mcpConfiguration: String(decoding: data, as: UTF8.self)
        )
    }
}

private struct MCPConfiguration: Codable {
    struct Server: Codable {
        let command: String
        let args: [String]
    }

    let mcpServers: [String: Server]
}
