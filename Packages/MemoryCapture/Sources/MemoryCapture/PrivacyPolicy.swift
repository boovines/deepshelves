import Foundation
import MemoryContracts

public enum PrivacyRuleAction: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

public enum PrivateBrowserHandling: String, Codable, Equatable, Sendable {
    case allow
    case exclude
}

public enum PrivacyRuleMatcher: Codable, Equatable, Sendable {
    case application(String)
    case hostExact(String)
    case hostSuffix(String)

    fileprivate var isSiteMatcher: Bool {
        switch self {
        case .application: false
        case .hostExact, .hostSuffix: true
        }
    }

    fileprivate func matches(bundleIdentifier: String, host: String?) -> Bool {
        switch self {
        case .application(let expected):
            return bundleIdentifier == expected
        case .hostExact(let expected):
            return host == Self.normalizeHost(expected)
        case .hostSuffix(let expected):
            let suffix = Self.normalizeHost(expected)
            guard let host, !suffix.isEmpty else { return false }
            return host == suffix || host.hasSuffix("." + suffix)
        }
    }

    fileprivate var normalized: Self {
        switch self {
        case .application(let bundleIdentifier):
            .application(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
        case .hostExact(let host):
            .hostExact(Self.normalizeHost(host))
        case .hostSuffix(let host):
            .hostSuffix(Self.normalizeHost(host))
        }
    }

    private static func normalizeHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

public struct PrivacyRule: Codable, Equatable, Sendable {
    public let id: String
    public let matcher: PrivacyRuleMatcher
    public let action: PrivacyRuleAction

    public init(id: String, matcher: PrivacyRuleMatcher, action: PrivacyRuleAction) {
        self.id = id
        self.matcher = matcher
        self.action = action
    }
}

public struct PrivacyPolicyConfiguration: Codable, Equatable, Sendable {
    public static let fixedRuleID = "fixed-system-exclusion"
    public static let passwordManagerRuleID = "password-manager-default"
    public static let privateBrowserRuleID = "private-browser-default"

    public let selfBundleIdentifier: String
    public let passwordManagerDefaultsVersion: String
    public let excludedPasswordManagerBundleIdentifiers: Set<String>
    public let privateBrowserHandling: PrivateBrowserHandling
    public let rules: [PrivacyRule]

    public var fixedExcludedBundleIdentifiers: Set<String> {
        Self.fixedSystemBundleIdentifiers.union([selfBundleIdentifier])
    }

    private static let fixedSystemBundleIdentifiers: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.SecurityAgent",
        "com.apple.CoreServicesUIAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.AuthenticationServicesUI.AuthenticationServicesAgent",
    ]

    private enum CodingKeys: String, CodingKey {
        case selfBundleIdentifier
        case passwordManagerDefaultsVersion
        case excludedPasswordManagerBundleIdentifiers
        case privateBrowserHandling
        case rules
    }

    private init(
        selfBundleIdentifier: String,
        passwordManagerDefaultsVersion: String,
        excludedPasswordManagerBundleIdentifiers: Set<String>,
        privateBrowserHandling: PrivateBrowserHandling,
        rules: [PrivacyRule]
    ) {
        self.selfBundleIdentifier = selfBundleIdentifier
        self.passwordManagerDefaultsVersion = passwordManagerDefaultsVersion
        self.excludedPasswordManagerBundleIdentifiers = excludedPasswordManagerBundleIdentifiers
        self.privateBrowserHandling = privateBrowserHandling
        self.rules = rules
    }

    public static func personalDefault(
        selfBundleIdentifier: String,
        rules: [PrivacyRule] = []
    ) -> Self {
        Self(
            selfBundleIdentifier: selfBundleIdentifier,
            passwordManagerDefaultsVersion: "2026-08-01.v1",
            excludedPasswordManagerBundleIdentifiers: [
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.bitwarden.desktop",
                "com.dashlane.Dashlane",
                "com.lastpass.LastPass",
                "com.apple.Passwords",
            ],
            privateBrowserHandling: .exclude,
            rules: rules
        )
    }

    public func replacingPasswordManagerExclusions(_ bundleIdentifiers: Set<String>) -> Self {
        Self(
            selfBundleIdentifier: selfBundleIdentifier,
            passwordManagerDefaultsVersion: passwordManagerDefaultsVersion,
            excludedPasswordManagerBundleIdentifiers: bundleIdentifiers,
            privateBrowserHandling: privateBrowserHandling,
            rules: rules
        )
    }

    public func replacingPrivateBrowserHandling(_ handling: PrivateBrowserHandling) -> Self {
        Self(
            selfBundleIdentifier: selfBundleIdentifier,
            passwordManagerDefaultsVersion: passwordManagerDefaultsVersion,
            excludedPasswordManagerBundleIdentifiers: excludedPasswordManagerBundleIdentifiers,
            privateBrowserHandling: handling,
            rules: rules
        )
    }

    public func replacingRules(_ rules: [PrivacyRule]) -> Self {
        Self(
            selfBundleIdentifier: selfBundleIdentifier,
            passwordManagerDefaultsVersion: passwordManagerDefaultsVersion,
            excludedPasswordManagerBundleIdentifiers: excludedPasswordManagerBundleIdentifiers,
            privateBrowserHandling: privateBrowserHandling,
            rules: rules
        )
    }
}

public struct PrivacyEvaluationContext: Equatable, Sendable {
    public var targetWindowID: UInt32?
    public var processID: Int32?
    public var bundleIdentifier: String?
    public var targetIsUniquelyResolved: Bool
    public var recordingIsActive: Bool
    public var screenIsLocked: Bool
    public var secureInputIsActive: Bool
    public var browserContext: BrowserContextResolution?
    public var captureEpochID: UUID?

    public init(
        targetWindowID: UInt32?,
        processID: Int32?,
        bundleIdentifier: String?,
        targetIsUniquelyResolved: Bool,
        recordingIsActive: Bool,
        screenIsLocked: Bool,
        secureInputIsActive: Bool,
        browserContext: BrowserContextResolution?,
        captureEpochID: UUID? = nil
    ) {
        self.targetWindowID = targetWindowID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.targetIsUniquelyResolved = targetIsUniquelyResolved
        self.recordingIsActive = recordingIsActive
        self.screenIsLocked = screenIsLocked
        self.secureInputIsActive = secureInputIsActive
        self.browserContext = browserContext
        self.captureEpochID = captureEpochID
    }
}

public enum PrivacyPolicyReason: String, Codable, Equatable, Sendable {
    case defaultAllow
    case userRule
    case recordingStopped
    case screenLocked
    case secureInputActive
    case missingTarget
    case ambiguousTarget
    case fixedApplicationExclusion
    case passwordManagerExclusion
    case privateBrowserDefault
    case browserContextUnavailable
    case staleTargetOrContext
    case stalePolicyGeneration
}

public enum PrivacyPolicyAuditResult: String, Codable, Equatable, Sendable {
    case allowed
    case denied
}

public struct PrivacyPolicyAudit: Equatable, Sendable {
    public let id: UUID
    public let decidedAt: Date
    public let bundleIdentifier: String?
    public let host: String?
    public let privateContext: Bool
    public let result: PrivacyPolicyAuditResult
    public let matchedRuleID: String?

    /// Policy audit rows deliberately contain no title, URL, text, media, or derived payload fields.
    public var contentFieldCount: Int { 0 }
}

public struct PrivacyPolicyDecision: Equatable, Sendable {
    public let isAllowed: Bool
    public let reason: PrivacyPolicyReason
    public let matchedRuleID: String?
    public let audit: PrivacyPolicyAudit
}

public struct PrivacyPolicyApproval: Equatable, Sendable {
    public let decision: PrivacyPolicyDecision
    fileprivate let policyGeneration: UInt64
    fileprivate let fingerprint: PrivacyContextFingerprint
}

public enum PrivacyPrefilterResult: Equatable, Sendable {
    case allowed(PrivacyPolicyApproval)
    case denied(PrivacyPolicyDecision)

    public var decision: PrivacyPolicyDecision {
        switch self {
        case .allowed(let approval): approval.decision
        case .denied(let decision): decision
        }
    }
}

private struct PrivacyContextFingerprint: Equatable, Sendable {
    let targetWindowID: UInt32
    let processID: Int32
    let bundleIdentifier: String
    let browserContext: BrowserContextResolution?
    let captureEpochID: UUID?
}

private struct CompiledPrivacyPolicy: Sendable {
    let fixedExcludedBundleIdentifiers: Set<String>
    let excludedPasswordManagerBundleIdentifiers: Set<String>
    let privateBrowserHandling: PrivateBrowserHandling
    let rules: [PrivacyRule]
    let hasSiteRules: Bool

    init(configuration: PrivacyPolicyConfiguration) {
        fixedExcludedBundleIdentifiers = configuration.fixedExcludedBundleIdentifiers
        excludedPasswordManagerBundleIdentifiers =
            configuration.excludedPasswordManagerBundleIdentifiers
        privateBrowserHandling = configuration.privateBrowserHandling
        rules = configuration.rules.map { rule in
            PrivacyRule(id: rule.id, matcher: rule.matcher.normalized, action: rule.action)
        }
        hasSiteRules = rules.contains { $0.matcher.isSiteMatcher }
    }
}

public actor PrivacyPolicy {
    private var compiledPolicy: CompiledPrivacyPolicy
    private var generation: UInt64 = 1

    public init(configuration: PrivacyPolicyConfiguration) {
        compiledPolicy = CompiledPrivacyPolicy(configuration: configuration)
    }

    public func replaceConfiguration(_ configuration: PrivacyPolicyConfiguration) {
        compiledPolicy = CompiledPrivacyPolicy(configuration: configuration)
        generation &+= 1
    }

    public func prefilter(context: PrivacyEvaluationContext) -> PrivacyPrefilterResult {
        let evaluation = evaluate(context)
        let decision = makeDecision(evaluation, context: context)
        guard decision.isAllowed, let fingerprint = fingerprint(context) else {
            return .denied(decision)
        }
        return .allowed(
            PrivacyPolicyApproval(
                decision: decision,
                policyGeneration: generation,
                fingerprint: fingerprint
            )
        )
    }

    public func finalRecheck(
        approval: PrivacyPolicyApproval,
        context: PrivacyEvaluationContext
    ) -> PrivacyPolicyDecision {
        guard approval.policyGeneration == generation else {
            return makeDecision(
                Evaluation(isAllowed: false, reason: .stalePolicyGeneration, matchedRuleID: nil),
                context: context
            )
        }
        guard fingerprint(context) == approval.fingerprint else {
            return makeDecision(
                Evaluation(isAllowed: false, reason: .staleTargetOrContext, matchedRuleID: nil),
                context: context
            )
        }
        return makeDecision(evaluate(context), context: context)
    }

    private struct Evaluation {
        let isAllowed: Bool
        let reason: PrivacyPolicyReason
        let matchedRuleID: String?
    }

    private func evaluate(_ context: PrivacyEvaluationContext) -> Evaluation {
        guard context.recordingIsActive else {
            return deny(.recordingStopped)
        }
        guard !context.screenIsLocked else {
            return deny(.screenLocked)
        }
        guard !context.secureInputIsActive else {
            return deny(.secureInputActive)
        }
        guard context.targetWindowID != nil,
            context.processID != nil,
            let bundleIdentifier = context.bundleIdentifier,
            !bundleIdentifier.isEmpty
        else {
            return deny(.missingTarget)
        }
        guard context.targetIsUniquelyResolved else {
            return deny(.ambiguousTarget)
        }
        if compiledPolicy.fixedExcludedBundleIdentifiers.contains(bundleIdentifier) {
            return deny(
                .fixedApplicationExclusion,
                matchedRuleID: PrivacyPolicyConfiguration.fixedRuleID
            )
        }
        if compiledPolicy.excludedPasswordManagerBundleIdentifiers.contains(bundleIdentifier) {
            return deny(
                .passwordManagerExclusion,
                matchedRuleID: PrivacyPolicyConfiguration.passwordManagerRuleID
            )
        }

        let adapter = BrowserAdapterRegistry.production.adapter(for: bundleIdentifier)
        var host: String?
        if adapter != nil {
            guard let browserContext = context.browserContext else {
                return deny(.browserContextUnavailable)
            }
            switch browserContext {
            case .approved(let output):
                guard output.targetWindowID == context.targetWindowID else {
                    return deny(.browserContextUnavailable)
                }
                host = output.context.origin.host
            case .privateContext(let output):
                guard output.targetWindowID == context.targetWindowID else {
                    return deny(.browserContextUnavailable)
                }
                if compiledPolicy.privateBrowserHandling == .exclude {
                    return deny(
                        .privateBrowserDefault,
                        matchedRuleID: PrivacyPolicyConfiguration.privateBrowserRuleID
                    )
                }
                if compiledPolicy.hasSiteRules {
                    return deny(.browserContextUnavailable)
                }
            case .unavailable:
                return deny(.browserContextUnavailable)
            }
        } else if case .some(.approved) = context.browserContext {
            return deny(.browserContextUnavailable)
        }

        var matchedRule: PrivacyRule?
        for rule in compiledPolicy.rules
        where rule.matcher.matches(bundleIdentifier: bundleIdentifier, host: host) {
            matchedRule = rule
        }
        if let matchedRule {
            return Evaluation(
                isAllowed: matchedRule.action == .allow,
                reason: .userRule,
                matchedRuleID: safeAuditIdentifier(matchedRule.id)
            )
        }
        return Evaluation(isAllowed: true, reason: .defaultAllow, matchedRuleID: nil)
    }

    private func deny(
        _ reason: PrivacyPolicyReason,
        matchedRuleID: String? = nil
    ) -> Evaluation {
        Evaluation(isAllowed: false, reason: reason, matchedRuleID: matchedRuleID)
    }

    private func fingerprint(_ context: PrivacyEvaluationContext) -> PrivacyContextFingerprint? {
        guard let targetWindowID = context.targetWindowID,
            let processID = context.processID,
            let bundleIdentifier = context.bundleIdentifier,
            context.targetIsUniquelyResolved
        else {
            return nil
        }
        return PrivacyContextFingerprint(
            targetWindowID: targetWindowID,
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            browserContext: context.browserContext,
            captureEpochID: context.captureEpochID
        )
    }

    private func makeDecision(
        _ evaluation: Evaluation,
        context: PrivacyEvaluationContext
    ) -> PrivacyPolicyDecision {
        let browserProjection = projectedBrowserContext(context.browserContext)
        let mayProjectContext = evaluation.isAllowed
        let audit = PrivacyPolicyAudit(
            id: UUID(),
            decidedAt: Date(),
            bundleIdentifier: mayProjectContext ? context.bundleIdentifier : nil,
            host: mayProjectContext ? browserProjection.host : nil,
            privateContext: browserProjection.isPrivate,
            result: evaluation.isAllowed ? .allowed : .denied,
            matchedRuleID: evaluation.matchedRuleID
        )
        return PrivacyPolicyDecision(
            isAllowed: evaluation.isAllowed,
            reason: evaluation.reason,
            matchedRuleID: evaluation.matchedRuleID,
            audit: audit
        )
    }

    private func projectedBrowserContext(
        _ resolution: BrowserContextResolution?
    ) -> (host: String?, isPrivate: Bool) {
        switch resolution {
        case .approved(let output): (output.context.origin.host, false)
        case .privateContext: (nil, true)
        case .unavailable, nil: (nil, false)
        }
    }

    private func safeAuditIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 128,
            value.unicodeScalars.allSatisfy({ scalar in
                scalar.properties.isAlphabetic
                    || scalar.properties.numericType != nil
                    || ".:_-".unicodeScalars.contains(scalar)
            })
        else {
            return nil
        }
        return value
    }
}

public struct PrivacyArtifactBundle: Equatable, Sendable {
    public var pixelPayloads: [String]
    public var textPayloads: [String]
    public var derivedArtifacts: [String]
    public var cachePayloads: [String]

    public init(
        pixelPayloads: [String] = [],
        textPayloads: [String] = [],
        derivedArtifacts: [String] = [],
        cachePayloads: [String] = []
    ) {
        self.pixelPayloads = pixelPayloads
        self.textPayloads = textPayloads
        self.derivedArtifacts = derivedArtifacts
        self.cachePayloads = cachePayloads
    }

    public static func sentinel(_ value: String) -> Self {
        Self(
            pixelPayloads: [value],
            textPayloads: [value],
            derivedArtifacts: [value],
            cachePayloads: [value]
        )
    }

    public var isEmpty: Bool {
        pixelPayloads.isEmpty
            && textPayloads.isEmpty
            && derivedArtifacts.isEmpty
            && cachePayloads.isEmpty
    }
}

public enum PrivacyPersistenceGate {
    public static func project(
        _ artifacts: PrivacyArtifactBundle,
        decision: PrivacyPolicyDecision
    ) -> PrivacyArtifactBundle {
        decision.isAllowed ? artifacts : PrivacyArtifactBundle()
    }
}

public struct LM022PrivacyFixtureCase: Equatable, Sendable {
    public let id: String
    public let context: PrivacyEvaluationContext
    public let expectedReason: PrivacyPolicyReason
}

public enum LM022PrivacyFixture {
    public static func make(seed: UInt64) -> [LM022PrivacyFixtureCase] {
        let rotation = Int(seed % 200)
        var fixtures: [LM022PrivacyFixtureCase] = []
        fixtures.reserveCapacity(1_000)

        for offset in 0..<200 {
            let index = (offset + rotation) % 200
            fixtures.append(
                LM022PrivacyFixtureCase(
                    id: "ambiguous-target-\(String(format: "%03d", index))",
                    context: context(index: index, unique: false),
                    expectedReason: .ambiguousTarget
                )
            )
        }
        for offset in 0..<200 {
            let index = (offset + rotation) % 200
            var missingContext = context(index: index)
            missingContext.targetWindowID = nil
            fixtures.append(
                LM022PrivacyFixtureCase(
                    id: "missing-target-\(String(format: "%03d", index))",
                    context: missingContext,
                    expectedReason: .missingTarget
                )
            )
        }
        for offset in 0..<200 {
            let index = (offset + rotation) % 200
            let windowID = UInt32(20_000 + index)
            fixtures.append(
                LM022PrivacyFixtureCase(
                    id: "private-context-\(String(format: "%03d", index))",
                    context: context(
                        index: index,
                        targetWindowID: windowID,
                        bundleIdentifier: "com.google.Chrome",
                        browserContext: .privateContext(
                            PrivateBrowserContextOutput(targetWindowID: windowID, family: .chrome)
                        )
                    ),
                    expectedReason: .privateBrowserDefault
                )
            )
        }
        for offset in 0..<200 {
            let index = (offset + rotation) % 200
            let windowID = UInt32(30_000 + index)
            let host = index.isMultiple(of: 2) ? "sensitive.test" : "sub.sensitive.test"
            let origin = try! BrowserOrigin(scheme: "https", host: host, path: "/fixture")
            let browser = try! MemoryContracts.BrowserContext(
                family: .chrome,
                origin: origin,
                isPrivateContext: false
            )
            fixtures.append(
                LM022PrivacyFixtureCase(
                    id: "site-denied-\(String(format: "%03d", index))",
                    context: context(
                        index: index,
                        targetWindowID: windowID,
                        bundleIdentifier: "com.google.Chrome",
                        browserContext: .approved(
                            ApprovedBrowserContextOutput(
                                targetWindowID: windowID,
                                context: browser,
                                serializedURL: "https" + "://" + host + "/fixture"
                            )
                        )
                    ),
                    expectedReason: .userRule
                )
            )
        }
        for offset in 0..<200 {
            let index = (offset + rotation) % 200
            let reason = BrowserContextUnavailableReason.allCases[
                index % BrowserContextUnavailableReason.allCases.count
            ]
            fixtures.append(
                LM022PrivacyFixtureCase(
                    id: "url-context-unavailable-\(String(format: "%03d", index))",
                    context: context(
                        index: index,
                        bundleIdentifier: "com.google.Chrome",
                        browserContext: .unavailable(reason)
                    ),
                    expectedReason: .browserContextUnavailable
                )
            )
        }
        return fixtures
    }

    private static func context(
        index: Int,
        targetWindowID: UInt32? = nil,
        unique: Bool = true,
        bundleIdentifier: String = "com.example.fixture",
        browserContext: BrowserContextResolution? = nil
    ) -> PrivacyEvaluationContext {
        PrivacyEvaluationContext(
            targetWindowID: targetWindowID ?? UInt32(10_000 + index),
            processID: Int32(1_000 + index),
            bundleIdentifier: bundleIdentifier,
            targetIsUniquelyResolved: unique,
            recordingIsActive: true,
            screenIsLocked: false,
            secureInputIsActive: false,
            browserContext: browserContext,
            captureEpochID: UUID(
                uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index))")
        )
    }
}
