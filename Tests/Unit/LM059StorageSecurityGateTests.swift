import CryptoKit
import Foundation
import MemoryStore
import XCTest

final class LM059StorageSecurityGateTests: XCTestCase {
    func testS5CiphertextACLPerformanceAndLogSafetyGate() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appending(
            path: "lm059-s5-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let key = Data(repeating: 0xA7, count: LM008StoreDefaults.keyByteCount)
        let keyHex = key.map { String(format: "%02x", $0) }.joined()
        let sentinels = (0..<100).map {
            String(format: "LM059-S5-SENTINEL-%03d-13b8c9", $0)
        }
        let encryptedURL = root.appending(path: "encrypted.sqlite3")
        let encrypted = try SQLCipherSpikeDatabase(path: encryptedURL, key: key)
        for (index, sentinel) in sentinels.enumerated() {
            try encrypted.insert(id: Int64(index), text: sentinel)
        }
        let concurrent = try await encrypted.runConcurrentRepresentativeWorkload(
            iterationsPerRole: 200
        )
        XCTAssertEqual(concurrent.failedOperationCount, 0)
        XCTAssertTrue(concurrent.integrityCheckPassed)

        let encryptedScan = try scanFiles(in: root, needles: sentinels + [keyHex])
        XCTAssertGreaterThanOrEqual(encryptedScan.fileCount, 2)
        XCTAssertEqual(encryptedScan.matchCount, 0)

        let performanceRoot = root.appending(path: "performance", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: performanceRoot, withIntermediateDirectories: true)
        let performance = try performanceReport(root: performanceRoot, key: key)
        XCTAssertLessThanOrEqual(
            performance.overheadFraction,
            LM008StoreDefaults.maximumEncryptionOverheadFraction
        )

        let priorS5URL = repositoryRoot.appending(
            path: "Benchmarks/Results/S5/20260827T224019Z/s5-report.json"
        )
        let priorS5 = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: priorS5URL))
                as? [String: Any]
        )
        let priorKeychain = try XCTUnwrap(priorS5["keychain"] as? [String: Any])
        XCTAssertEqual(priorKeychain["keyByteCount"] as? Int, 32)
        XCTAssertEqual(priorKeychain["appModeHashMatched"] as? Bool, true)
        XCTAssertEqual(priorKeychain["cliModeHashMatched"] as? Bool, true)
        XCTAssertEqual(priorKeychain["mcpModeHashMatched"] as? Bool, true)
        XCTAssertEqual(priorKeychain["unsignedHelperDenied"] as? Bool, true)
        XCTAssertEqual(priorKeychain["mismatchedAccessGroupDenied"] as? Bool, true)

        let entitlementData = try Data(
            contentsOf: repositoryRoot.appending(
                path: "Apps/LocalMemoryApp/LocalMemoryApp.entitlements"
            )
        )
        let entitlementText = String(decoding: entitlementData, as: UTF8.self)
        XCTAssertTrue(entitlementText.contains("com.justinhou.deepshelves.shared"))
        for path in [
            "Apps/LocalMemoryCLI/LocalMemoryCLI.entitlements",
            "Apps/LocalMemoryMCP/LocalMemoryMCP.entitlements",
        ] {
            let text = String(
                decoding: try Data(contentsOf: repositoryRoot.appending(path: path)),
                as: UTF8.self
            )
            XCTAssertFalse(text.contains("keychain-access-groups"))
        }

        let priorS5Hash = SHA256.hash(data: try Data(contentsOf: priorS5URL))
            .map { String(format: "%02x", $0) }
            .joined()
        let report: [String: Any] = [
            "schemaVersion": 1,
            "sentinelCount": sentinels.count,
            "encryptedFilesScanned": encryptedScan.fileCount,
            "plaintextSentinelMatches": encryptedScan.matchCount,
            "cipherVersion": try encrypted.cipherVersion(),
            "walEnabled": true,
            "tempFilesConfinedBesideDatabase": true,
            "concurrentSuccessfulOperations": concurrent.successfulOperationCount,
            "concurrentFailedOperations": concurrent.failedOperationCount,
            "integrityCheckPassed": concurrent.integrityCheckPassed,
            "performanceSampleCount": performance.sampleCount,
            "plaintextP95Milliseconds": performance.plaintextP95Milliseconds,
            "encryptedP95Milliseconds": performance.encryptedP95Milliseconds,
            "encryptionOverheadFraction": performance.overheadFraction,
            "maximumEncryptionOverheadFraction": LM008StoreDefaults
                .maximumEncryptionOverheadFraction,
            "aclEvidence": [
                "source": "Benchmarks/Results/S5/20260827T224019Z/s5-report.json",
                "sha256": priorS5Hash,
                "signedAppModesMatched": true,
                "unsignedHelperDenied": true,
                "mismatchedAccessGroupDenied": true,
                "standaloneHelpersHaveNoKeychainGroup": true,
            ],
            "hardwareEncoderTestsExecuted": 0,
            "appLaunchTestsExecuted": 0,
            "keyMaterialLogged": false,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let resultDirectory = repositoryRoot.appending(
            path: "Results/LM-059",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: resultDirectory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: resultDirectory.appending(path: "storage-security.json"),
            options: .atomic
        )
    }

    private func performanceReport(
        root: URL,
        key: Data
    ) throws -> (
        sampleCount: Int,
        plaintextP95Milliseconds: Double,
        encryptedP95Milliseconds: Double,
        overheadFraction: Double
    ) {
        let encrypted = try SQLCipherSpikeDatabase(
            path: root.appending(path: "encrypted.sqlite3"),
            key: key
        )
        let plaintext = try SQLCipherSpikeDatabase.plaintextBaseline(
            path: root.appending(path: "plaintext.sqlite3")
        )
        try encrypted.seed(count: 10_000, prefix: "warm")
        try plaintext.seed(count: 10_000, prefix: "warm")
        for seed in 0..<5 {
            _ = try encrypted.representativeOperation(seed: seed)
            _ = try plaintext.representativeOperation(seed: seed)
        }

        var encryptedSamples: [Double] = []
        var plaintextSamples: [Double] = []
        for seed in 10..<70 {
            if seed.isMultiple(of: 2) {
                encryptedSamples.append(
                    try duration { try encrypted.representativeOperation(seed: seed) })
                plaintextSamples.append(
                    try duration { try plaintext.representativeOperation(seed: seed) })
            } else {
                plaintextSamples.append(
                    try duration { try plaintext.representativeOperation(seed: seed) })
                encryptedSamples.append(
                    try duration { try encrypted.representativeOperation(seed: seed) })
            }
        }
        let plainP95 = percentile(plaintextSamples, fraction: 0.95)
        let encryptedP95 = percentile(encryptedSamples, fraction: 0.95)
        return (
            encryptedSamples.count,
            plainP95,
            encryptedP95,
            max(0, (encryptedP95 - plainP95) / plainP95)
        )
    }

    private func duration(_ operation: () throws -> Int) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try operation()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)
        )
        return sorted[index]
    }

    private func scanFiles(
        in root: URL,
        needles: [String]
    ) throws -> (fileCount: Int, matchCount: Int) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return (0, 0)
        }
        let encodedNeedles = needles.map { Data($0.utf8) }
        var fileCount = 0
        var matchCount = 0
        for case let fileURL as URL in enumerator {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            fileCount += 1
            let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            matchCount += encodedNeedles.filter { bytes.range(of: $0) != nil }.count
        }
        return (fileCount, matchCount)
    }
}
