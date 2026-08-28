import Foundation
import MemoryContracts

public enum PrivacyPolicySettingsError: Error, Equatable, Sendable {
    case emptySelfBundleIdentifier
    case emptyRuleIdentifier
    case duplicateRuleIdentifier(String)
    case invalidApplicationIdentifier(String)
    case invalidHost(String)
    case invalidRuleIndex(Int)
    case unknownRuleIdentifier(String)
    case allowedDecisionCannotCreateGap
}

public protocol PrivacyPolicySettingsPersisting: Sendable {
    func load() async throws -> PrivacyPolicyConfiguration?
    func save(_ configuration: PrivacyPolicyConfiguration) async throws
}

public actor InMemoryPrivacyPolicySettingsStore: PrivacyPolicySettingsPersisting {
    private var configuration: PrivacyPolicyConfiguration?

    public init(configuration: PrivacyPolicyConfiguration? = nil) {
        self.configuration = configuration
    }

    public func load() -> PrivacyPolicyConfiguration? {
        configuration
    }

    public func save(_ configuration: PrivacyPolicyConfiguration) {
        self.configuration = configuration
    }
}

public actor FilePrivacyPolicySettingsStore: PrivacyPolicySettingsPersisting {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> PrivacyPolicyConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            PrivacyPolicyConfiguration.self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func save(_ configuration: PrivacyPolicyConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }
}

public struct PrivacyPolicySettingsSnapshot: Equatable, Sendable {
    public let configuration: PrivacyPolicyConfiguration
    public let policyGeneration: UInt64

    public init(
        configuration: PrivacyPolicyConfiguration,
        policyGeneration: UInt64
    ) {
        self.configuration = configuration
        self.policyGeneration = policyGeneration
    }
}

public struct PrivacyPolicyUpdateReceipt: Equatable, Sendable {
    public let configuration: PrivacyPolicyConfiguration
    public let policyGeneration: UInt64
    public let effectiveNanoseconds: UInt64

    public init(
        configuration: PrivacyPolicyConfiguration,
        policyGeneration: UInt64,
        effectiveNanoseconds: UInt64
    ) {
        self.configuration = configuration
        self.policyGeneration = policyGeneration
        self.effectiveNanoseconds = effectiveNanoseconds
    }
}

public struct PrivacyPolicyPreview: Equatable, Sendable {
    public let isAllowed: Bool
    public let reason: PrivacyPolicyReason
    public let matchedRuleID: String?
    public let visibleRuleLabel: String

    public init(
        isAllowed: Bool,
        reason: PrivacyPolicyReason,
        matchedRuleID: String?,
        visibleRuleLabel: String
    ) {
        self.isAllowed = isAllowed
        self.reason = reason
        self.matchedRuleID = matchedRuleID
        self.visibleRuleLabel = visibleRuleLabel
    }
}

public actor PrivacyPolicySettingsController {
    public nonisolated let policy: PrivacyPolicy

    private let defaultConfiguration: PrivacyPolicyConfiguration
    private let store: any PrivacyPolicySettingsPersisting
    private let clock: any ActivityMonotonicClock
    private var configuration: PrivacyPolicyConfiguration

    public init(
        defaultConfiguration: PrivacyPolicyConfiguration,
        policy: PrivacyPolicy,
        store: any PrivacyPolicySettingsPersisting,
        clock: any ActivityMonotonicClock = SystemActivityMonotonicClock()
    ) {
        self.defaultConfiguration = defaultConfiguration
        self.policy = policy
        self.store = store
        self.clock = clock
        configuration = defaultConfiguration
    }

    @discardableResult
    public func load() async throws -> PrivacyPolicySettingsSnapshot {
        if let stored = try await store.load() {
            let validated = try Self.validated(stored)
            configuration = validated
            _ = await policy.replaceConfiguration(validated)
        } else {
            configuration = try Self.validated(defaultConfiguration)
        }
        return await snapshot()
    }

    public func snapshot() async -> PrivacyPolicySettingsSnapshot {
        PrivacyPolicySettingsSnapshot(
            configuration: configuration,
            policyGeneration: await policy.currentGeneration()
        )
    }

    @discardableResult
    public func appendApplicationExclusion(
        bundleIdentifier: String,
        ruleID: String
    ) async throws -> PrivacyPolicyUpdateReceipt {
        try await replaceRules(
            configuration.rules + [
                PrivacyRule(
                    id: ruleID,
                    matcher: .application(bundleIdentifier),
                    action: .deny
                )
            ]
        )
    }

    @discardableResult
    public func appendSiteExclusion(
        host: String,
        includeSubdomains: Bool,
        ruleID: String
    ) async throws -> PrivacyPolicyUpdateReceipt {
        let matcher: PrivacyRuleMatcher =
            includeSubdomains ? .hostSuffix(host) : .hostExact(host)
        return try await replaceRules(
            configuration.rules + [
                PrivacyRule(id: ruleID, matcher: matcher, action: .deny)
            ]
        )
    }

    @discardableResult
    public func replaceRules(
        _ rules: [PrivacyRule]
    ) async throws -> PrivacyPolicyUpdateReceipt {
        try await commit(configuration.replacingRules(rules))
    }

    @discardableResult
    public func moveRule(
        id: String,
        to destinationIndex: Int
    ) async throws -> PrivacyPolicyUpdateReceipt {
        guard let sourceIndex = configuration.rules.firstIndex(where: { $0.id == id }) else {
            throw PrivacyPolicySettingsError.unknownRuleIdentifier(id)
        }
        guard configuration.rules.indices.contains(destinationIndex) else {
            throw PrivacyPolicySettingsError.invalidRuleIndex(destinationIndex)
        }
        var rules = configuration.rules
        let rule = rules.remove(at: sourceIndex)
        rules.insert(rule, at: destinationIndex)
        return try await replaceRules(rules)
    }

    @discardableResult
    public func removeRule(id: String) async throws -> PrivacyPolicyUpdateReceipt {
        guard configuration.rules.contains(where: { $0.id == id }) else {
            throw PrivacyPolicySettingsError.unknownRuleIdentifier(id)
        }
        return try await replaceRules(configuration.rules.filter { $0.id != id })
    }

    public func preview(context: PrivacyEvaluationContext) async throws -> PrivacyPolicyPreview {
        let result = await policy.prefilter(context: context)
        return PrivacyPolicyPreview(
            isAllowed: result.decision.isAllowed,
            reason: result.decision.reason,
            matchedRuleID: result.decision.matchedRuleID,
            visibleRuleLabel: visibleRuleLabel(for: result.decision)
        )
    }

    private func commit(
        _ proposedConfiguration: PrivacyPolicyConfiguration
    ) async throws -> PrivacyPolicyUpdateReceipt {
        let validated = try Self.validated(proposedConfiguration)
        try await store.save(validated)
        let policyGeneration = await policy.replaceConfiguration(validated)
        configuration = validated
        return PrivacyPolicyUpdateReceipt(
            configuration: validated,
            policyGeneration: policyGeneration,
            effectiveNanoseconds: clock.nowNanoseconds()
        )
    }

    private func visibleRuleLabel(for decision: PrivacyPolicyDecision) -> String {
        guard let matchedRuleID = decision.matchedRuleID,
            let rule = configuration.rules.last(where: { $0.id == matchedRuleID })
        else {
            return Self.defaultLabel(for: decision.reason)
        }
        return Self.visibleLabel(for: rule)
    }

    private static func visibleLabel(for rule: PrivacyRule) -> String {
        let verb = rule.action == .deny ? "Block" : "Allow"
        switch rule.matcher {
        case .application(let bundleIdentifier):
            return "\(verb) \(bundleIdentifier)"
        case .hostExact(let host):
            return "\(verb) \(normalizeHost(host))"
        case .hostSuffix(let host):
            return "\(verb) \(normalizeHost(host)) and subdomains"
        }
    }

    private static func defaultLabel(for reason: PrivacyPolicyReason) -> String {
        switch reason {
        case .defaultAllow: "Allowed by default"
        case .recordingStopped: "Recording is paused"
        case .screenLocked: "Screen is locked"
        case .secureInputActive: "Secure input is active"
        case .missingTarget: "No foreground window is available"
        case .ambiguousTarget: "Foreground window is ambiguous"
        case .fixedApplicationExclusion: "Blocked by a fixed system exclusion"
        case .passwordManagerExclusion: "Blocked by password-manager defaults"
        case .privateBrowserDefault: "Blocked by private-window handling"
        case .browserContextUnavailable: "Browser capture paused to protect site exclusions"
        case .staleTargetOrContext: "Context changed before persistence"
        case .stalePolicyGeneration: "Privacy rules changed before persistence"
        case .userRule: "Matched an ordered user rule"
        }
    }

    private static func validated(
        _ configuration: PrivacyPolicyConfiguration
    ) throws -> PrivacyPolicyConfiguration {
        guard
            !configuration.selfBundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw PrivacyPolicySettingsError.emptySelfBundleIdentifier
        }
        var ruleIDs: Set<String> = []
        var normalizedRules: [PrivacyRule] = []
        normalizedRules.reserveCapacity(configuration.rules.count)
        for rule in configuration.rules {
            let ruleID = rule.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ruleID.isEmpty else {
                throw PrivacyPolicySettingsError.emptyRuleIdentifier
            }
            guard ruleIDs.insert(ruleID).inserted else {
                throw PrivacyPolicySettingsError.duplicateRuleIdentifier(ruleID)
            }
            let matcher: PrivacyRuleMatcher
            switch rule.matcher {
            case .application(let rawBundleIdentifier):
                let bundleIdentifier = rawBundleIdentifier.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard Self.isValidBundleIdentifier(bundleIdentifier) else {
                    throw PrivacyPolicySettingsError.invalidApplicationIdentifier(
                        rawBundleIdentifier
                    )
                }
                matcher = .application(bundleIdentifier)
            case .hostExact(let rawHost):
                let host = normalizeHost(rawHost)
                guard isValidHost(host) else {
                    throw PrivacyPolicySettingsError.invalidHost(rawHost)
                }
                matcher = .hostExact(host)
            case .hostSuffix(let rawHost):
                let host = normalizeHost(rawHost)
                guard isValidHost(host) else {
                    throw PrivacyPolicySettingsError.invalidHost(rawHost)
                }
                matcher = .hostSuffix(host)
            }
            normalizedRules.append(
                PrivacyRule(id: ruleID, matcher: matcher, action: rule.action)
            )
        }
        return configuration.replacingRules(normalizedRules)
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || ".-_".unicodeScalars.contains(scalar)
        }
    }

    private static func normalizeHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isValidHost(_ value: String) -> Bool {
        var components = URLComponents()
        components.scheme = "https"
        components.host = value
        guard value.count <= 253, value.contains("."),
            components.host == value,
            components.url != nil,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.path.isEmpty
        else {
            return false
        }
        return value.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

public enum PrivacyPolicyExposureGate {
    public static func project<Value>(
        _ value: Value,
        decision: PrivacyPolicyDecision
    ) -> Value? {
        decision.isAllowed ? value : nil
    }
}

public enum PrivacyPolicyTimelineGapProjector {
    public static func gap(
        for decision: PrivacyPolicyDecision,
        startedAt: Date,
        endedAt: Date
    ) throws -> RecordingGap {
        guard !decision.isAllowed else {
            throw PrivacyPolicySettingsError.allowedDecisionCannotCreateGap
        }
        return try gap(
            for: decision.reason,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    public static func gap(
        for reason: PrivacyPolicyReason,
        startedAt: Date,
        endedAt: Date
    ) throws -> RecordingGap {
        guard reason != .defaultAllow else {
            throw PrivacyPolicySettingsError.allowedDecisionCannotCreateGap
        }
        return try RecordingGap(
            startedAt: startedAt,
            endedAt: endedAt,
            reason: recordingGapReason(for: reason),
            approvedBundleID: nil
        )
    }

    public static func recordingGapReason(
        for reason: PrivacyPolicyReason
    ) -> RecordingGapReason {
        switch reason {
        case .defaultAllow:
            .unknown
        case .userRule, .fixedApplicationExclusion, .passwordManagerExclusion,
            .privateBrowserDefault:
            .excluded
        case .recordingStopped:
            .paused
        case .screenLocked, .secureInputActive:
            .protectedSurface
        case .missingTarget:
            .noWindow
        case .ambiguousTarget:
            .ambiguousWindow
        case .browserContextUnavailable, .staleTargetOrContext, .stalePolicyGeneration:
            .filterFailed
        }
    }
}
