import Foundation
import MemoryCapture

private struct LM021BrowserContextRecord: Codable {
    let id: String
    let expected: String
    let actual: String
    let bundleIdentifier: String
    let targetWindowID: UInt32
    let approvedHost: String?
    let serializedURL: String?
}

private struct LM021BrowserContextReport: Codable {
    let schemaVersion: Int
    let seed: UInt64
    let supportedBrowsers: [String]
    let contextCount: Int
    let exactResolutionCount: Int
    let exactAccuracy: Double
    let approvedCount: Int
    let privateCount: Int
    let unavailableCounts: [String: Int]
    let uniqueTargetAssociationCount: Int
    let sanitizedApprovedSerializationCount: Int
    let privateContentFieldCount: Int
    let addressFieldOnly: Bool
    let publicAccessibilityOnly: Bool
    let inspectedDOMOrNetworkTraffic: Bool
    let records: [LM021BrowserContextRecord]
    let allInvariantsPassed: Bool
}

enum LM021BrowserContextHarness {
    private static let seed: UInt64 = 1_279_938_621

    static func run() throws -> Data {
        let fixtures = LM021BrowserContextFixture.make(seed: seed)
        let adapter = BrowserAddressFieldAdapter()
        var exactCount = 0
        var approvedCount = 0
        var privateCount = 0
        var unavailableCounts: [String: Int] = [:]
        var uniqueTargetAssociationCount = 0
        var sanitizedCount = 0
        var privateContentFieldCount = 0
        let records = try fixtures.map { fixture in
            let actual = adapter.inspect(fixture.observation)
            if actual == fixture.expectedResolution {
                exactCount += 1
            }
            var approvedHost: String?
            var serializedURL: String?
            switch actual {
            case let .approved(output):
                approvedCount += 1
                approvedHost = output.context.origin.host
                serializedURL = output.serializedURL
                if output.targetWindowID == fixture.observation.target.windowID {
                    uniqueTargetAssociationCount += 1
                }
                let encoded = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
                if !encoded.contains("credential-sentinel")
                    && !encoded.contains("query-sentinel")
                    && !encoded.contains("fragment-sentinel")
                    && !encoded.contains("@")
                {
                    sanitizedCount += 1
                }
            case let .privateContext(output):
                privateCount += 1
                if output.targetWindowID == fixture.observation.target.windowID {
                    uniqueTargetAssociationCount += 1
                }
                let encoded = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
                if encoded.contains("example.test") || encoded.contains("sentinel") {
                    privateContentFieldCount += 1
                }
            case let .unavailable(reason):
                unavailableCounts[reason.rawValue, default: 0] += 1
            }
            return LM021BrowserContextRecord(
                id: fixture.id,
                expected: fixture.expectedResolution.evidenceName,
                actual: actual.evidenceName,
                bundleIdentifier: fixture.observation.target.bundleIdentifier,
                targetWindowID: fixture.observation.target.windowID,
                approvedHost: approvedHost,
                serializedURL: serializedURL
            )
        }
        let accuracy = Double(exactCount) / Double(fixtures.count)
        let report = LM021BrowserContextReport(
            schemaVersion: 1,
            seed: seed,
            supportedBrowsers: SupportedBrowser.allCases.map(\.rawValue),
            contextCount: fixtures.count,
            exactResolutionCount: exactCount,
            exactAccuracy: accuracy,
            approvedCount: approvedCount,
            privateCount: privateCount,
            unavailableCounts: unavailableCounts,
            uniqueTargetAssociationCount: uniqueTargetAssociationCount,
            sanitizedApprovedSerializationCount: sanitizedCount,
            privateContentFieldCount: privateContentFieldCount,
            addressFieldOnly: true,
            publicAccessibilityOnly: true,
            inspectedDOMOrNetworkTraffic: false,
            records: records,
            allInvariantsPassed: fixtures.count == 600
                && exactCount == fixtures.count
                && accuracy >= 0.98
                && approvedCount == 480
                && privateCount == 30
                && unavailableCounts == [
                    "ambiguousAddressField": 15,
                    "privateStateUnavailable": 15,
                    "targetWindowMismatch": 30,
                    "unsupportedURL": 15,
                    "urlUnavailable": 15,
                ]
                && uniqueTargetAssociationCount == 510
                && sanitizedCount == approvedCount
                && privateContentFieldCount == 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

private extension BrowserContextResolution {
    var evidenceName: String {
        switch self {
        case let .approved(output):
            "approved:\(output.targetWindowID):\(output.context.origin.host)"
        case let .privateContext(output):
            "privateContext:\(output.targetWindowID):\(output.family.rawValue)"
        case let .unavailable(reason):
            "unavailable:\(reason.rawValue)"
        }
    }
}
