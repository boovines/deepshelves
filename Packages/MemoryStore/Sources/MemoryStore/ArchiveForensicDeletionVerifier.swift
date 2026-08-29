import CryptoKit
import Foundation
import GRDB

public struct ArchiveForensicDeletionRequest: Sendable {
    public let deletedFrameIDs: Set<UUID>
    public let sentinelValues: [Data]
    public let helperProjections: [Data]
    public let codecTemporaryDirectories: [URL]
    public let activeProcessNames: [String]
    public let prohibitedCodecProcessNames: Set<String>
    public let signingKey: Data
    public let scannedAt: Date

    public init(
        deletedFrameIDs: Set<UUID>,
        sentinelValues: [Data],
        helperProjections: [Data],
        codecTemporaryDirectories: [URL],
        activeProcessNames: [String],
        prohibitedCodecProcessNames: Set<String>,
        signingKey: Data,
        scannedAt: Date
    ) {
        self.deletedFrameIDs = deletedFrameIDs
        self.sentinelValues = sentinelValues
        self.helperProjections = helperProjections
        self.codecTemporaryDirectories = codecTemporaryDirectories
        self.activeProcessNames = activeProcessNames
        self.prohibitedCodecProcessNames = prohibitedCodecProcessNames
        self.signingKey = signingKey
        self.scannedAt = scannedAt
    }
}

public struct ArchiveForensicSurfaceResult: Codable, Equatable, Sendable {
    public let scannedItemCount: Int
    public let violationCount: Int
}

public struct ArchiveForensicDeletionReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scannedAt: Date
    public let passed: Bool
    public let deletedIdentityCount: Int
    public let sentinelCount: Int
    public let surfaces: [String: ArchiveForensicSurfaceResult]
    public let checkpointAndVacuumCompleted: Bool
    public let tombstoneIdentityMetadataExcluded: Bool
    public let verificationHash: String
    public let signatureAlgorithm: String
    public let signingKeyIdentity: String
    public let signature: String

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum ArchiveForensicDeletionError: Error, Equatable, Sendable {
    case invalidRequest
    case fileBackedArchiveRequired
    case symbolicLinkForbidden
    case scanFailure
}

public final class ArchiveForensicDeletionVerifier: @unchecked Sendable {
    public static let reportSchemaVersion = 1

    private let database: ArchiveDatabase
    private let paths: ArchivePaths
    private let fileManager: FileManager

    public init(database: ArchiveDatabase, fileManager: FileManager = .default) throws {
        guard let paths = database.paths else {
            throw ArchiveForensicDeletionError.fileBackedArchiveRequired
        }
        self.database = database
        self.paths = paths
        self.fileManager = fileManager
    }

    public func verify(_ request: ArchiveForensicDeletionRequest) throws
        -> ArchiveForensicDeletionReport
    {
        guard !request.deletedFrameIDs.isEmpty,
            !request.sentinelValues.isEmpty,
            request.sentinelValues.allSatisfy({ !$0.isEmpty }),
            request.signingKey.count == 32,
            request.scannedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ArchiveForensicDeletionError.invalidRequest
        }
        let needles = Self.needles(request)
        try database.checkpointAndVacuumForForensicDeletion()

        var surfaces: [String: ArchiveForensicSurfaceResult] = [:]
        surfaces["database.logicalContent"] = try logicalDatabaseScan(request)
        surfaces["database.encryptedBytes"] = try fileScan(
            urls: databaseFiles(),
            needles: needles
        )
        surfaces["media"] = try treeScan(paths.media, needles: needles)
        surfaces["thumbnails"] = try treeScan(paths.thumbnails, needles: needles)
        surfaces["vectors"] = try treeScan(paths.vectors, needles: needles)
        surfaces["logs"] = try treeScan(paths.logs, needles: needles)
        surfaces["exports"] = try treeScan(paths.exports, needles: needles)
        surfaces["quarantine"] = try treeScan(paths.quarantine, needles: needles)
        surfaces["helperProjections"] = dataScan(
            request.helperProjections,
            needles: needles
        )
        surfaces["codecTemporaryResidue"] = try rootsScan(
            request.codecTemporaryDirectories,
            needles: needles
        )
        surfaces["codecProcesses"] = processScan(request)

        let passed = surfaces.values.allSatisfy { $0.violationCount == 0 }
        let unsigned = UnsignedForensicReport(
            schemaVersion: Self.reportSchemaVersion,
            scannedAt: request.scannedAt,
            passed: passed,
            deletedIdentityCount: request.deletedFrameIDs.count,
            sentinelCount: request.sentinelValues.count,
            surfaces: surfaces,
            checkpointAndVacuumCompleted: true,
            tombstoneIdentityMetadataExcluded: true
        )
        let unsignedData = try Self.encode(unsigned)
        let verificationHash = Data(SHA256.hash(data: unsignedData))
        let keyIdentity = Data(SHA256.hash(data: request.signingKey))
        let signature = Data(
            HMAC<SHA256>.authenticationCode(
                for: unsignedData,
                using: SymmetricKey(data: request.signingKey)
            )
        )
        return ArchiveForensicDeletionReport(
            schemaVersion: unsigned.schemaVersion,
            scannedAt: unsigned.scannedAt,
            passed: unsigned.passed,
            deletedIdentityCount: unsigned.deletedIdentityCount,
            sentinelCount: unsigned.sentinelCount,
            surfaces: unsigned.surfaces,
            checkpointAndVacuumCompleted: unsigned.checkpointAndVacuumCompleted,
            tombstoneIdentityMetadataExcluded: unsigned.tombstoneIdentityMetadataExcluded,
            verificationHash: verificationHash.lowercaseHex,
            signatureAlgorithm: "HMAC-SHA256",
            signingKeyIdentity: keyIdentity.lowercaseHex,
            signature: signature.lowercaseHex
        )
    }

    public static func verifySignature(
        _ report: ArchiveForensicDeletionReport,
        signingKey: Data
    ) -> Bool {
        guard signingKey.count == 32,
            let signature = Data(lowercaseHex: report.signature),
            let verificationHash = Data(lowercaseHex: report.verificationHash)
        else { return false }
        let unsigned = UnsignedForensicReport(
            schemaVersion: report.schemaVersion,
            scannedAt: report.scannedAt,
            passed: report.passed,
            deletedIdentityCount: report.deletedIdentityCount,
            sentinelCount: report.sentinelCount,
            surfaces: report.surfaces,
            checkpointAndVacuumCompleted: report.checkpointAndVacuumCompleted,
            tombstoneIdentityMetadataExcluded: report.tombstoneIdentityMetadataExcluded
        )
        guard let encoded = try? encode(unsigned),
            Data(SHA256.hash(data: encoded)) == verificationHash
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: encoded,
            using: SymmetricKey(data: signingKey)
        )
    }

    private func logicalDatabaseScan(_ request: ArchiveForensicDeletionRequest) throws
        -> ArchiveForensicSurfaceResult
    {
        try database.atomicRead { database in
            var violations = 0
            let frameIDs = request.deletedFrameIDs.map(\.encoded)
            let placeholders = Self.placeholders(frameIDs.count)
            for table in [
                "frames", "text_spans", "artifacts", "vector_offsets", "merged_text_records",
            ] {
                let column = table == "frames" ? "id" : "frame_id"
                violations +=
                    try Int.fetchOne(
                        database,
                        sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IN (\(placeholders))",
                        arguments: StatementArguments(frameIDs)
                    ) ?? 0
            }
            for sentinel in request.sentinelValues {
                guard let text = String(data: sentinel, encoding: .utf8) else { continue }
                violations += try Self.contentMatches(text, database: database)
            }
            return ArchiveForensicSurfaceResult(
                scannedItemCount: frameIDs.count + request.sentinelValues.count,
                violationCount: violations
            )
        }
    }

    private static func contentMatches(_ value: String, database: Database) throws -> Int {
        var count = 0
        let queries = [
            "SELECT COUNT(*) FROM frames WHERE instr(approved_text, ?) > 0 OR instr(COALESCE(window_title, ''), ?) > 0 OR instr(COALESCE(app_name, ''), ?) > 0 OR instr(COALESCE(url_host, ''), ?) > 0 OR instr(COALESCE(url_path, ''), ?) > 0",
            "SELECT COUNT(*) FROM text_spans WHERE instr(text, ?) > 0",
            "SELECT COUNT(*) FROM merged_text_records WHERE instr(approved_text, ?) > 0 OR instr(transcript_text, ?) > 0 OR instr(COALESCE(window_title, ''), ?) > 0 OR instr(COALESCE(app_name, ''), ?) > 0 OR instr(COALESCE(url_host, ''), ?) > 0 OR instr(COALESCE(url_path, ''), ?) > 0",
            "SELECT COUNT(*) FROM artifacts WHERE instr(locator_value, ?) > 0",
        ]
        for (index, sql) in queries.enumerated() {
            let argumentCount = [5, 1, 6, 1][index]
            count +=
                try Int.fetchOne(
                    database,
                    sql: sql,
                    arguments: StatementArguments(Array(repeating: value, count: argumentCount))
                ) ?? 0
        }
        return count
    }

    private func databaseFiles() -> [URL] {
        let base = paths.databaseFile
        return [
            base,
            URL(fileURLWithPath: base.path + "-wal"),
            URL(fileURLWithPath: base.path + "-shm"),
        ].filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func rootsScan(_ roots: [URL], needles: [Data]) throws
        -> ArchiveForensicSurfaceResult
    {
        var scanned = 0
        var violations = 0
        for root in roots {
            let result = try treeScan(root, needles: needles)
            scanned += result.scannedItemCount
            violations += result.violationCount
        }
        return ArchiveForensicSurfaceResult(
            scannedItemCount: scanned,
            violationCount: violations
        )
    }

    private func treeScan(_ root: URL, needles: [Data]) throws
        -> ArchiveForensicSurfaceResult
    {
        guard fileManager.fileExists(atPath: root.path) else {
            return ArchiveForensicSurfaceResult(scannedItemCount: 0, violationCount: 0)
        }
        try ArchivePathProvider.rejectSymbolicLink(at: root, fileManager: fileManager)
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else {
            throw ArchiveForensicDeletionError.scanFailure
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw ArchiveForensicDeletionError.symbolicLinkForbidden
            }
            if values.isRegularFile == true { urls.append(url) }
        }
        return try fileScan(urls: urls, needles: needles)
    }

    private func fileScan(urls: [URL], needles: [Data]) throws
        -> ArchiveForensicSurfaceResult
    {
        var violations = 0
        for url in urls {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            violations += needles.reduce(0) { count, needle in
                count + (data.range(of: needle) == nil ? 0 : 1)
            }
        }
        return ArchiveForensicSurfaceResult(
            scannedItemCount: urls.count,
            violationCount: violations
        )
    }

    private func dataScan(_ values: [Data], needles: [Data])
        -> ArchiveForensicSurfaceResult
    {
        let violations = values.reduce(0) { total, value in
            total
                + needles.reduce(0) { count, needle in
                    count + (value.range(of: needle) == nil ? 0 : 1)
                }
        }
        return ArchiveForensicSurfaceResult(
            scannedItemCount: values.count,
            violationCount: violations
        )
    }

    private func processScan(_ request: ArchiveForensicDeletionRequest)
        -> ArchiveForensicSurfaceResult
    {
        let normalized = Set(request.activeProcessNames.map { $0.lowercased() })
        let prohibited = Set(request.prohibitedCodecProcessNames.map { $0.lowercased() })
        return ArchiveForensicSurfaceResult(
            scannedItemCount: normalized.count,
            violationCount: normalized.intersection(prohibited).count
        )
    }

    private static func needles(_ request: ArchiveForensicDeletionRequest) -> [Data] {
        var values = request.sentinelValues
        for identifier in request.deletedFrameIDs {
            values.append(Data(identifier.encoded.utf8))
            values.append(Data(identifier.uuidString.uppercased().utf8))
        }
        return Array(Set(values))
    }

    private static func encode(_ value: UnsignedForensicReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

private struct UnsignedForensicReport: Codable {
    let schemaVersion: Int
    let scannedAt: Date
    let passed: Bool
    let deletedIdentityCount: Int
    let sentinelCount: Int
    let surfaces: [String: ArchiveForensicSurfaceResult]
    let checkpointAndVacuumCompleted: Bool
    let tombstoneIdentityMetadataExcluded: Bool
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}

extension Data {
    fileprivate init?(lowercaseHex value: String) {
        guard value.count.isMultiple(of: 2),
            value.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
        else { return nil }
        self.init()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }

    fileprivate var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}
