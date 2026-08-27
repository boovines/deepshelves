import AVFoundation
import CoreVideo
import CryptoKit
import Foundation

public struct LM008KeychainProbeResult: Codable, Equatable, Sendable {
    public let role: String
    public let status: Int32
    public let keyHashMatched: Bool

    public init(role: String, status: Int32, keyHashMatched: Bool) {
        self.role = role
        self.status = status
        self.keyHashMatched = keyHashMatched
    }
}

public struct S5KeychainReport: Codable, Equatable, Sendable {
    public let keyByteCount: Int
    public let appModeStatus: Int32
    public let cliModeStatus: Int32
    public let mcpModeStatus: Int32
    public let unsignedProbeStatus: Int32
    public let mismatchedAccessGroupStatus: Int32
    public let appModeHashMatched: Bool
    public let cliModeHashMatched: Bool
    public let mcpModeHashMatched: Bool
    public let unsignedHelperDenied: Bool
    public let mismatchedAccessGroupDenied: Bool
    public let helperPackaging: String
}

public struct S5EncryptionReport: Codable, Equatable, Sendable {
    public let cipherVersion: String
    public let sentinelCount: Int
    public let filesScannedBeforeDeletion: Int
    public let plaintextMatchesBeforeDeletion: Int
    public let walEnabled: Bool
    public let tempStore: String
    public let concurrentWorkload: S5ConcurrentWorkloadResult
}

public struct S5PerformanceReport: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let plaintextP95Milliseconds: Double
    public let encryptedP95Milliseconds: Double
    public let encryptionOverheadFraction: Double
}

public struct S5ProcessCrashReport: Codable, Equatable, Sendable {
    public let forcedTerminationCount: Int
    public let consistentRecoveryCount: Int
    public let boundaries: [String]
}

public struct S5DeletionReport: Codable, Equatable, Sendable {
    public let filesScannedAfterDeletion: Int
    public let plaintextMatchesAfterDeletion: Int
    public let databaseRowsAfterDeletion: Int
    public let seededMediaDecodedBeforeDeletion: Bool
    public let seededMediaAbsentAfterDeletion: Bool
    public let mediaFilesDecodedAfterDeletion: Int
    public let mediaDecodeSentinelCount: Int
    public let helperProjectionSentinelCount: Int
}

public struct S5SpikeReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let keychain: S5KeychainReport
    public let encryption: S5EncryptionReport
    public let performance: S5PerformanceReport
    public let faultInjection: S5CrashRecoveryReport
    public let processCrashes: S5ProcessCrashReport
    public let deletion: S5DeletionReport
}

public enum S5SpikeError: Error, Equatable, Sendable {
    case outputAlreadyExists
    case childProcessFailed(String, Int32)
    case invalidProbeOutput
    case inconsistentCrashRecovery(String)
}

public enum S5SpikeRunner: Sendable {
    public static func run(
        outputDirectory: URL,
        signedExecutableURL: URL,
        unsignedProbeURL: URL,
        deletionMediaFixtureURL: URL
    ) async throws -> S5SpikeReport {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputDirectory.path) else {
            throw S5SpikeError.outputAlreadyExists
        }
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let raw = outputDirectory.appending(path: "raw", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: raw, withIntermediateDirectories: true)

        let account = "lm008-\(UUID().uuidString.lowercased())"
        let key = try SharedKeychainKeyStore.generateAndStore(account: account)
        defer {
            try? SharedKeychainKeyStore.delete(account: account, ignoreMissing: true)
        }
        let expectedHash = sha256Hex(key)

        let appProbe = LM008KeychainProbeResult(
            role: "app",
            status: 0,
            keyHashMatched: sha256Hex(try SharedKeychainKeyStore.fetch(account: account)) == expectedHash
        )
        let cliProbe = try runKeychainProbe(
            executableURL: signedExecutableURL,
            role: "cli",
            account: account,
            expectedHash: expectedHash,
            outputURL: raw.appending(path: "cli-keychain-probe.json")
        )
        let mcpProbe = try runKeychainProbe(
            executableURL: signedExecutableURL,
            role: "mcp",
            account: account,
            expectedHash: expectedHash,
            outputURL: raw.appending(path: "mcp-keychain-probe.json")
        )
        let unsignedProbe = try runUnsignedProbe(
            executableURL: unsignedProbeURL,
            account: account,
            outputURL: raw.appending(path: "unsigned-keychain-probe.json")
        )
        let mismatchStatus = SharedKeychainKeyStore.statusForFetch(
            account: account,
            accessGroup: "NS5L7NNR8U.com.justinhou.deepshelves.mismatch"
        )

        let keychainReport = S5KeychainReport(
            keyByteCount: key.count,
            appModeStatus: appProbe.status,
            cliModeStatus: cliProbe.status,
            mcpModeStatus: mcpProbe.status,
            unsignedProbeStatus: unsignedProbe.status,
            mismatchedAccessGroupStatus: mismatchStatus,
            appModeHashMatched: appProbe.keyHashMatched,
            cliModeHashMatched: cliProbe.keyHashMatched,
            mcpModeHashMatched: mcpProbe.keyHashMatched,
            unsignedHelperDenied: unsignedProbe.status != 0 && !unsignedProbe.keyHashMatched,
            mismatchedAccessGroupDenied: mismatchStatus != 0,
            helperPackaging: "signed application executable with --cli/--mcp modes"
        )

        let sentinels = (0..<100).map {
            String(format: "LM008-S5-SENTINEL-%03d-7f6e5d4c", $0)
        }
        let databaseRoot = raw.appending(path: "database", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: databaseRoot, withIntermediateDirectories: true)
        let databaseURL = databaseRoot.appending(path: "archive.sqlite3")
        let database = try SQLCipherSpikeDatabase(path: databaseURL, key: key)
        for (index, sentinel) in sentinels.enumerated() {
            try database.insert(id: Int64(index), text: sentinel)
        }

        let concurrentDatabase = try SQLCipherSpikeDatabase(
            path: databaseRoot.appending(path: "concurrent.sqlite3"),
            key: key
        )
        let concurrent = try await concurrentDatabase.runConcurrentRepresentativeWorkload(
            iterationsPerRole: 200
        )
        let beforeScan = try scanFiles(in: databaseRoot, needles: sentinels)

        let performance = try performanceReport(
            root: raw.appending(path: "performance", directoryHint: .isDirectory),
            key: key
        )
        let faultInjection = try S5CrashRecoveryModel.verify(
            crashPointCount: LM008StoreDefaults.crashPointCount
        )
        let processCrashes = try runForcedTerminationScenarios(
            root: raw.appending(path: "process-crashes", directoryHint: .isDirectory),
            executableURL: signedExecutableURL,
            account: account,
            key: key
        )

        let seededArtifacts = raw.appending(path: "seeded-artifacts", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: seededArtifacts, withIntermediateDirectories: true)
        let seededPaths = ["vectors.f16", "thumbnail.heic", "local.log", "helper.json"]
            .map { seededArtifacts.appending(path: $0) }
        let seededData = Data(sentinels.joined(separator: "\n").utf8)
        for path in seededPaths {
            try seededData.write(to: path, options: .atomic)
        }
        let seededMediaURL = seededArtifacts.appending(path: "media.mov")
        try fileManager.copyItem(at: deletionMediaFixtureURL, to: seededMediaURL)
        let deletedMediaHash = try sha256File(seededMediaURL)
        let seededMediaDecodedBeforeDeletion = try await decodesFirstVideoFrame(seededMediaURL)
        guard seededMediaDecodedBeforeDeletion else {
            throw S5SpikeError.inconsistentCrashRecovery("seeded-media-decode")
        }

        try database.delete(ids: 0..<sentinels.count)
        try database.checkpoint()
        try database.vacuum()
        for path in seededPaths {
            if fileManager.fileExists(atPath: path.path) {
                try fileManager.removeItem(at: path)
            }
        }
        try removeIfPresent(seededMediaURL)
        let cleanProjection = try database.allTexts().joined(separator: "\n")
        try Data(cleanProjection.utf8).write(
            to: seededArtifacts.appending(path: "helper.json"),
            options: .atomic
        )
        try Data("clean-vector\n".utf8).write(
            to: seededArtifacts.appending(path: "vectors.f16"),
            options: .atomic
        )

        let afterScan = try scanFiles(in: raw, needles: sentinels)
        let remainingRows = try database.allTexts()
        let mediaAfterDeletion = try await decodedMediaReport(
            in: seededArtifacts,
            deletedHash: deletedMediaHash
        )
        let deletion = S5DeletionReport(
            filesScannedAfterDeletion: afterScan.fileCount,
            plaintextMatchesAfterDeletion: afterScan.matchCount,
            databaseRowsAfterDeletion: remainingRows.count,
            seededMediaDecodedBeforeDeletion: seededMediaDecodedBeforeDeletion,
            seededMediaAbsentAfterDeletion: !fileManager.fileExists(atPath: seededMediaURL.path),
            mediaFilesDecodedAfterDeletion: mediaAfterDeletion.decodedCount,
            mediaDecodeSentinelCount: mediaAfterDeletion.deletedHashMatches,
            helperProjectionSentinelCount: remainingRows.filter { sentinels.contains($0) }.count
        )

        let report = S5SpikeReport(
            schemaVersion: 1,
            keychain: keychainReport,
            encryption: S5EncryptionReport(
                cipherVersion: try database.cipherVersion(),
                sentinelCount: sentinels.count,
                filesScannedBeforeDeletion: beforeScan.fileCount,
                plaintextMatchesBeforeDeletion: beforeScan.matchCount,
                walEnabled: true,
                tempStore: "FILE beside encrypted database via benchmark TMPDIR",
                concurrentWorkload: concurrent
            ),
            performance: performance,
            faultInjection: faultInjection,
            processCrashes: processCrashes,
            deletion: deletion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: outputDirectory.appending(path: "s5-report.json"),
            options: .atomic
        )
        return report
    }

    private static func performanceReport(root: URL, key: Data) throws -> S5PerformanceReport {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
                let encryptedStart = DispatchTime.now().uptimeNanoseconds
                _ = try encrypted.representativeOperation(seed: seed)
                encryptedSamples.append(milliseconds(since: encryptedStart))
                let plainStart = DispatchTime.now().uptimeNanoseconds
                _ = try plaintext.representativeOperation(seed: seed)
                plaintextSamples.append(milliseconds(since: plainStart))
            } else {
                let plainStart = DispatchTime.now().uptimeNanoseconds
                _ = try plaintext.representativeOperation(seed: seed)
                plaintextSamples.append(milliseconds(since: plainStart))
                let encryptedStart = DispatchTime.now().uptimeNanoseconds
                _ = try encrypted.representativeOperation(seed: seed)
                encryptedSamples.append(milliseconds(since: encryptedStart))
            }
        }
        let plainP95 = percentile(plaintextSamples, fraction: 0.95)
        let encryptedP95 = percentile(encryptedSamples, fraction: 0.95)
        return S5PerformanceReport(
            sampleCount: encryptedSamples.count,
            plaintextP95Milliseconds: plainP95,
            encryptedP95Milliseconds: encryptedP95,
            encryptionOverheadFraction: max(0, (encryptedP95 - plainP95) / plainP95)
        )
    }

    private static func runForcedTerminationScenarios(
        root: URL,
        executableURL: URL,
        account: String,
        key: Data
    ) throws -> S5ProcessCrashReport {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let boundaries = ["partial-write", "ready-rename", "database-commit", "old-file-delete"]
        var recovered = 0
        for (index, boundary) in boundaries.enumerated() {
            let caseRoot = root.appending(path: String(format: "case-%02d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
            let oldURL = caseRoot.appending(path: "old.mov")
            try Data("old-ready".utf8).write(to: oldURL)
            let database = try SQLCipherSpikeDatabase(
                path: caseRoot.appending(path: "crash.sqlite3"),
                key: key
            )
            try database.insert(id: -1, text: "old.mov")

            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                "--lm008-crash-child",
                caseRoot.path,
                String(index),
                account,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == Int32(90 + index) else {
                throw S5SpikeError.childProcessFailed(boundary, process.terminationStatus)
            }

            let readyPath = try database.text(id: -1) ?? ""
            let partialURL = caseRoot.appending(path: "candidate.mov.partial")
            let candidateURL = caseRoot.appending(path: "candidate.mov")
            if readyPath == "old.mov" {
                try removeIfPresent(partialURL)
                try removeIfPresent(candidateURL)
            } else if readyPath == "candidate.mov" {
                try removeIfPresent(partialURL)
                try removeIfPresent(oldURL)
            } else {
                throw S5SpikeError.inconsistentCrashRecovery(boundary)
            }
            let readyURLs = [oldURL, candidateURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard readyURLs.count == 1, readyURLs[0].lastPathComponent == readyPath else {
                throw S5SpikeError.inconsistentCrashRecovery(boundary)
            }
            recovered += 1
        }
        return S5ProcessCrashReport(
            forcedTerminationCount: boundaries.count,
            consistentRecoveryCount: recovered,
            boundaries: boundaries
        )
    }

    private static func runKeychainProbe(
        executableURL: URL,
        role: String,
        account: String,
        expectedHash: String,
        outputURL: URL
    ) throws -> LM008KeychainProbeResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--lm008-keychain-probe",
            role,
            outputURL.path,
            account,
            expectedHash,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw S5SpikeError.childProcessFailed(role, process.terminationStatus)
        }
        guard let result = try? JSONDecoder().decode(
            LM008KeychainProbeResult.self,
            from: Data(contentsOf: outputURL)
        ) else {
            throw S5SpikeError.invalidProbeOutput
        }
        return result
    }

    private static func runUnsignedProbe(
        executableURL: URL,
        account: String,
        outputURL: URL
    ) throws -> LM008KeychainProbeResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            SharedKeychainKeyStore.accessGroup,
            SharedKeychainKeyStore.service,
            account,
            outputURL.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let result = try? JSONDecoder().decode(
                  LM008KeychainProbeResult.self,
                  from: Data(contentsOf: outputURL)
              )
        else {
            throw S5SpikeError.invalidProbeOutput
        }
        return result
    }

    private static func scanFiles(
        in root: URL,
        needles: [String]
    ) throws -> (fileCount: Int, matchCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        let needleData = needles.map { Data($0.utf8) }
        var fileCount = 0
        var matchCount = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            for needle in needleData where data.range(of: needle) != nil {
                matchCount += 1
            }
        }
        return (fileCount, matchCount)
    }

    private static func decodedMediaReport(
        in root: URL,
        deletedHash: String
    ) async throws -> (decodedCount: Int, deletedHashMatches: Int) {
        let mediaURLs = try regularMOVURLs(in: root)
        var decodedCount = 0
        var deletedHashMatches = 0
        for fileURL in mediaURLs {
            guard try await decodesFirstVideoFrame(fileURL) else { continue }
            decodedCount += 1
            if try sha256File(fileURL) == deletedHash {
                deletedHashMatches += 1
            }
        }
        return (decodedCount, deletedHashMatches)
    }

    private static func regularMOVURLs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var mediaURLs: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "mov" {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            mediaURLs.append(fileURL)
        }
        return mediaURLs
    }

    private static func decodesFirstVideoFrame(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return false
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        return output.copyNextSampleBuffer() != nil && reader.status != .failed
    }

    private static func sha256File(_ url: URL) throws -> String {
        sha256Hex(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)
        return sorted[index]
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
