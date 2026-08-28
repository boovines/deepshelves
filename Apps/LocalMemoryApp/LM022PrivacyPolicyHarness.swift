import Foundation
import MemoryCapture
import MemoryStore

private struct LM022PrivacyPolicyRecord: Codable {
    let id: String
    let expectedReason: String
    let actualReason: String
    let matchedRuleID: String?
    let projectedArtifactCount: Int
    let auditContentFieldCount: Int
}

private struct LM022PrivacyPolicyReport: Codable {
    let schemaVersion: Int
    let seed: UInt64
    let fixtureCount: Int
    let exactDecisionCount: Int
    let deniedCount: Int
    let reasonCounts: [String: Int]
    let backgroundSentinelSceneCount: Int
    let persistedPixelPayloadCount: Int
    let persistedTextPayloadCount: Int
    let persistedDerivedArtifactCount: Int
    let persistedCachePayloadCount: Int
    let auditRowCount: Int
    let auditContentFieldCount: Int
    let deniedAuditContextFieldCount: Int
    let fixedExclusionCount: Int
    let fixedExclusionOverrideCount: Int
    let passwordManagerDefaultsVersion: String
    let passwordManagerDefaultsEditable: Bool
    let privateBrowserDefaultEditable: Bool
    let finalTargetRecheckPassed: Bool
    let finalEpochRecheckPassed: Bool
    let finalPolicyGenerationRecheckPassed: Bool
    let records: [LM022PrivacyPolicyRecord]
    let allInvariantsPassed: Bool
}

private final class LM022BlockingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func set(_ result: Result<Data, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result!
    }
}

enum LM022PrivacyPolicyHarness {
    private static let seed: UInt64 = 1_279_938_622
    private static let selfBundleIdentifier = "com.justinhou.deepshelves.localmemory"

    static func runBlocking() throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let output = LM022BlockingResult()
        Task.detached {
            do {
                output.set(.success(try await run()))
            } catch {
                output.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try output.get().get()
    }

    private static func run() async throws -> Data {
        let configuration = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: selfBundleIdentifier,
            rules: [
                PrivacyRule(
                    id: "deny-sensitive",
                    matcher: .hostSuffix("sensitive.test"),
                    action: .deny
                )
            ]
        )
        let policy = PrivacyPolicy(configuration: configuration)
        let archive = try ArchiveDatabase.deterministicTestStore()
        let artifacts = PrivacyArtifactBundle.sentinel("LM022_PROHIBITED_CONTENT_SENTINEL")
        let fixtures = LM022PrivacyFixture.make(seed: seed)
        var exactDecisionCount = 0
        var deniedCount = 0
        var reasonCounts: [String: Int] = [:]
        var persistedPixelPayloadCount = 0
        var persistedTextPayloadCount = 0
        var persistedDerivedArtifactCount = 0
        var persistedCachePayloadCount = 0
        var records: [LM022PrivacyPolicyRecord] = []
        records.reserveCapacity(fixtures.count)

        for fixture in fixtures {
            let result = await policy.prefilter(context: fixture.context)
            let decision = result.decision
            if decision.reason == fixture.expectedReason {
                exactDecisionCount += 1
            }
            if !decision.isAllowed {
                deniedCount += 1
            }
            reasonCounts[decision.reason.rawValue, default: 0] += 1
            let projection = PrivacyPersistenceGate.project(artifacts, decision: decision)
            persistedPixelPayloadCount += projection.pixelPayloads.count
            persistedTextPayloadCount += projection.textPayloads.count
            persistedDerivedArtifactCount += projection.derivedArtifacts.count
            persistedCachePayloadCount += projection.cachePayloads.count
            let audit = decision.audit
            try archive.recordPolicyDecision(
                id: audit.id,
                decidedAt: audit.decidedAt,
                bundleIdentifier: audit.bundleIdentifier,
                host: audit.host,
                privateContext: audit.privateContext,
                result: audit.result.rawValue,
                matchedRuleID: audit.matchedRuleID
            )
            records.append(
                LM022PrivacyPolicyRecord(
                    id: fixture.id,
                    expectedReason: fixture.expectedReason.rawValue,
                    actualReason: decision.reason.rawValue,
                    matchedRuleID: decision.matchedRuleID,
                    projectedArtifactCount: projection.pixelPayloads.count
                        + projection.textPayloads.count
                        + projection.derivedArtifacts.count
                        + projection.cachePayloads.count,
                    auditContentFieldCount: audit.contentFieldCount
                )
            )
        }

        var fixedExclusionOverrideCount = 0
        for bundleIdentifier in configuration.fixedExcludedBundleIdentifiers {
            let overridingPolicy = PrivacyPolicy(
                configuration: configuration.replacingRules([
                    PrivacyRule(
                        id: "attempted-fixed-override",
                        matcher: .application(bundleIdentifier),
                        action: .allow
                    )
                ])
            )
            let result = await overridingPolicy.prefilter(
                context: PrivacyEvaluationContext(
                    targetWindowID: 91,
                    processID: 42,
                    bundleIdentifier: bundleIdentifier,
                    targetIsUniquelyResolved: true,
                    recordingIsActive: true,
                    screenIsLocked: false,
                    secureInputIsActive: false,
                    browserContext: nil,
                    captureEpochID: UUID(uuidString: "00000000-0000-0000-0000-000000000091")
                )
            )
            if result.decision.isAllowed {
                fixedExclusionOverrideCount += 1
            }
        }

        let passwordManagerDefaultsEditable =
            configuration
            .replacingPasswordManagerExclusions([])
            .excludedPasswordManagerBundleIdentifiers.isEmpty
        let privateBrowserDefaultEditable =
            configuration
            .replacingPrivateBrowserHandling(.allow)
            .privateBrowserHandling == .allow

        let racePolicy = PrivacyPolicy(configuration: configuration.replacingRules([]))
        let originalEpoch = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let baseContext = PrivacyEvaluationContext(
            targetWindowID: 101,
            processID: 51,
            bundleIdentifier: "com.example.approved",
            targetIsUniquelyResolved: true,
            recordingIsActive: true,
            screenIsLocked: false,
            secureInputIsActive: false,
            browserContext: nil,
            captureEpochID: originalEpoch
        )
        let prefilter = await racePolicy.prefilter(context: baseContext)
        guard case .allowed(let approval) = prefilter else {
            throw LM022HarnessError.expectedApproval
        }
        var changedTarget = baseContext
        changedTarget.targetWindowID = 102
        let targetDecision = await racePolicy.finalRecheck(
            approval: approval,
            context: changedTarget
        )
        var changedEpoch = baseContext
        changedEpoch.captureEpochID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")
        let epochDecision = await racePolicy.finalRecheck(
            approval: approval,
            context: changedEpoch
        )
        await racePolicy.replaceConfiguration(configuration)
        let generationDecision = await racePolicy.finalRecheck(
            approval: approval,
            context: baseContext
        )

        let auditRows = try archive.policyDecisionRecords()
        let auditContentFieldCount = auditRows.reduce(0) { $0 + $1.contentFieldCount }
        let deniedAuditContextFieldCount = auditRows.reduce(0) { partial, row in
            partial + (row.bundleIdentifier == nil ? 0 : 1) + (row.host == nil ? 0 : 1)
        }
        let allInvariantsPassed =
            fixtures.count == 1_000
            && exactDecisionCount == fixtures.count
            && deniedCount == fixtures.count
            && persistedPixelPayloadCount == 0
            && persistedTextPayloadCount == 0
            && persistedDerivedArtifactCount == 0
            && persistedCachePayloadCount == 0
            && auditRows.count == fixtures.count
            && auditContentFieldCount == 0
            && deniedAuditContextFieldCount == 0
            && fixedExclusionOverrideCount == 0
            && passwordManagerDefaultsEditable
            && privateBrowserDefaultEditable
            && targetDecision.reason == .staleTargetOrContext
            && epochDecision.reason == .staleTargetOrContext
            && generationDecision.reason == .stalePolicyGeneration

        let report = LM022PrivacyPolicyReport(
            schemaVersion: 1,
            seed: seed,
            fixtureCount: fixtures.count,
            exactDecisionCount: exactDecisionCount,
            deniedCount: deniedCount,
            reasonCounts: reasonCounts,
            backgroundSentinelSceneCount: fixtures.count,
            persistedPixelPayloadCount: persistedPixelPayloadCount,
            persistedTextPayloadCount: persistedTextPayloadCount,
            persistedDerivedArtifactCount: persistedDerivedArtifactCount,
            persistedCachePayloadCount: persistedCachePayloadCount,
            auditRowCount: auditRows.count,
            auditContentFieldCount: auditContentFieldCount,
            deniedAuditContextFieldCount: deniedAuditContextFieldCount,
            fixedExclusionCount: configuration.fixedExcludedBundleIdentifiers.count,
            fixedExclusionOverrideCount: fixedExclusionOverrideCount,
            passwordManagerDefaultsVersion: configuration.passwordManagerDefaultsVersion,
            passwordManagerDefaultsEditable: passwordManagerDefaultsEditable,
            privateBrowserDefaultEditable: privateBrowserDefaultEditable,
            finalTargetRecheckPassed: targetDecision.reason == .staleTargetOrContext,
            finalEpochRecheckPassed: epochDecision.reason == .staleTargetOrContext,
            finalPolicyGenerationRecheckPassed: generationDecision.reason
                == .stalePolicyGeneration,
            records: records,
            allInvariantsPassed: allInvariantsPassed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

private enum LM022HarnessError: Error {
    case expectedApproval
}
