import Foundation
import OSLog

public enum LocalDiagnosticsError: Error, Equatable, Sendable {
    case invalidRecord
    case invalidConfiguration
    case recordTooLarge
    case invalidLog
    case invalidSnapshot
    case exportFailed
}

public enum LocalDiagnosticEvent: String, Codable, CaseIterable, Sendable {
    case stateTransition
    case queueDepth
    case duration
    case captureDisposition
    case resourceSample
    case error
}

public enum LocalDiagnosticState: String, Codable, CaseIterable, Sendable {
    case recording
    case paused
    case idle
    case unavailable
    case stopped
}

public enum LocalDiagnosticMetric: String, Codable, CaseIterable, Sendable {
    case acceptedFrames
    case deduplicatedFrames
    case droppedFrames
    case excludedFrames
    case pendingAccessibilityJobs
    case pendingOCRJobs
    case pendingIndexJobs
    case durationMilliseconds
    case searchLatencyMilliseconds
    case residentMemoryBytes
    case databaseBytes
    case mediaBytes
    case logBytes
    case projectedMonthlyStorageBytes
    case cpuPercent
}

public struct LocalDiagnosticRecord: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let event: LocalDiagnosticEvent
    public let state: LocalDiagnosticState?
    public let captureID: UUID?
    public let errorCode: String?
    public let metrics: [LocalDiagnosticMetric: Double]

    public init(
        occurredAt: Date,
        event: LocalDiagnosticEvent,
        state: LocalDiagnosticState?,
        captureID: UUID?,
        errorCode: String?,
        metrics: [LocalDiagnosticMetric: Double]
    ) throws {
        guard occurredAt.timeIntervalSince1970.isFinite,
            metrics.count <= LocalDiagnosticMetric.allCases.count,
            metrics.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
            Self.validErrorCode(errorCode)
        else {
            throw LocalDiagnosticsError.invalidRecord
        }
        self.occurredAt = occurredAt
        self.event = event
        self.state = state
        self.captureID = captureID
        self.errorCode = errorCode
        self.metrics = metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            event: container.decode(LocalDiagnosticEvent.self, forKey: .event),
            state: container.decodeIfPresent(LocalDiagnosticState.self, forKey: .state),
            captureID: container.decodeIfPresent(UUID.self, forKey: .captureID),
            errorCode: container.decodeIfPresent(String.self, forKey: .errorCode),
            metrics: container.decode([LocalDiagnosticMetric: Double].self, forKey: .metrics)
        )
    }

    private static func validErrorCode(_ value: String?) -> Bool {
        guard let value else { return true }
        guard (3...64).contains(value.utf8.count), value.hasPrefix("LM-") else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0)
        }
    }
}

public enum ContentFreeDiagnosticCodec {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public final class ContentFreeDiagnosticLogger: @unchecked Sendable {
    private let directory: URL
    private let maximumFileBytes: Int
    private let maximumFiles: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        directory: URL,
        maximumFileBytes: Int = 1_048_576,
        maximumFiles: Int = 3,
        fileManager: FileManager = .default
    ) throws {
        guard maximumFileBytes >= 256, (1...10).contains(maximumFiles) else {
            throw LocalDiagnosticsError.invalidConfiguration
        }
        self.directory = directory.standardizedFileURL
        self.maximumFileBytes = maximumFileBytes
        self.maximumFiles = maximumFiles
        self.fileManager = fileManager
        try prepareDirectory()
    }

    public func append(_ record: LocalDiagnosticRecord) throws {
        var line = try ContentFreeDiagnosticCodec.encoder.encode(record)
        line.append(0x0A)
        guard line.count <= maximumFileBytes, line.count <= 8_192 else {
            throw LocalDiagnosticsError.recordTooLarge
        }
        try lock.withLock {
            let current = logURL(index: 0)
            try validateLogFileIfPresent(current)
            let existingSize = try fileSize(current)
            if existingSize + line.count > maximumFileBytes {
                try rotate()
            }
            if !fileManager.fileExists(atPath: current.path) {
                guard
                    fileManager.createFile(
                        atPath: current.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                else {
                    throw LocalDiagnosticsError.invalidLog
                }
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: current.path
            )
        }
    }

    public func logFiles() throws -> [URL] {
        try lock.withLock {
            try (0..<maximumFiles).compactMap { index in
                let url = logURL(index: index)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                try validateLogFileIfPresent(url)
                guard try fileSize(url) <= maximumFileBytes else {
                    throw LocalDiagnosticsError.invalidLog
                }
                return url
            }
        }
    }

    public func records() throws -> [LocalDiagnosticRecord] {
        try lock.withLock {
            var result: [LocalDiagnosticRecord] = []
            for url in try existingLogFiles().reversed() {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= maximumFileBytes else {
                    throw LocalDiagnosticsError.invalidLog
                }
                for line in data.split(separator: 0x0A) {
                    guard line.count <= 8_192 else { throw LocalDiagnosticsError.invalidLog }
                    do {
                        result.append(
                            try ContentFreeDiagnosticCodec.decoder.decode(
                                LocalDiagnosticRecord.self,
                                from: Data(line)
                            )
                        )
                    } catch {
                        throw LocalDiagnosticsError.invalidLog
                    }
                }
            }
            return result
        }
    }

    private func prepareDirectory() throws {
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LocalDiagnosticsError.invalidConfiguration
            }
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func rotate() throws {
        guard maximumFiles > 1 else {
            let current = logURL(index: 0)
            if fileManager.fileExists(atPath: current.path) {
                try fileManager.removeItem(at: current)
            }
            return
        }
        for destinationIndex in stride(from: maximumFiles - 1, through: 1, by: -1) {
            let source = logURL(index: destinationIndex - 1)
            let destination = logURL(index: destinationIndex)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
            }
        }
    }

    private func existingLogFiles() throws -> [URL] {
        try (0..<maximumFiles).compactMap { index in
            let url = logURL(index: index)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            try validateLogFileIfPresent(url)
            guard try fileSize(url) <= maximumFileBytes else {
                throw LocalDiagnosticsError.invalidLog
            }
            return url
        }
    }

    private func logURL(index: Int) -> URL {
        directory.appending(
            path: index == 0 ? "local-memory.log" : "local-memory.log.\(index)",
            directoryHint: .notDirectory
        )
    }

    private func fileSize(_ url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func validateLogFileIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalDiagnosticsError.invalidLog
        }
    }
}

public enum LocalEnergyCondition: String, Codable, CaseIterable, Sendable {
    case nominal
    case elevated
    case constrained
    case unavailable
}

public struct LocalDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let energyCondition: LocalEnergyCondition
    public let residentMemoryBytes: Int64
    public let databaseBytes: Int64
    public let mediaBytes: Int64
    public let logBytes: Int64
    public let projectedMonthlyStorageBytes: Int64?
    public let pendingIndexJobs: Int
    public let lastErrorCode: String?

    public init(
        measuredAt: Date,
        energyCondition: LocalEnergyCondition,
        residentMemoryBytes: Int64,
        databaseBytes: Int64,
        mediaBytes: Int64,
        logBytes: Int64,
        projectedMonthlyStorageBytes: Int64?,
        pendingIndexJobs: Int,
        lastErrorCode: String?
    ) throws {
        guard measuredAt.timeIntervalSince1970.isFinite,
            [residentMemoryBytes, databaseBytes, mediaBytes, logBytes].allSatisfy({ $0 >= 0 }),
            projectedMonthlyStorageBytes.map({ $0 >= 0 }) ?? true,
            pendingIndexJobs >= 0,
            Self.validErrorCode(lastErrorCode)
        else {
            throw LocalDiagnosticsError.invalidSnapshot
        }
        self.measuredAt = measuredAt
        self.energyCondition = energyCondition
        self.residentMemoryBytes = residentMemoryBytes
        self.databaseBytes = databaseBytes
        self.mediaBytes = mediaBytes
        self.logBytes = logBytes
        self.projectedMonthlyStorageBytes = projectedMonthlyStorageBytes
        self.pendingIndexJobs = pendingIndexJobs
        self.lastErrorCode = lastErrorCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            measuredAt: container.decode(Date.self, forKey: .measuredAt),
            energyCondition: container.decode(LocalEnergyCondition.self, forKey: .energyCondition),
            residentMemoryBytes: container.decode(Int64.self, forKey: .residentMemoryBytes),
            databaseBytes: container.decode(Int64.self, forKey: .databaseBytes),
            mediaBytes: container.decode(Int64.self, forKey: .mediaBytes),
            logBytes: container.decode(Int64.self, forKey: .logBytes),
            projectedMonthlyStorageBytes: container.decodeIfPresent(
                Int64.self,
                forKey: .projectedMonthlyStorageBytes
            ),
            pendingIndexJobs: container.decode(Int.self, forKey: .pendingIndexJobs),
            lastErrorCode: container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        )
    }

    public var totalStorageBytes: Int64 { databaseBytes + mediaBytes + logBytes }

    private static func validErrorCode(_ value: String?) -> Bool {
        guard let value else { return true }
        return
            (try? LocalDiagnosticRecord(
                occurredAt: Date(timeIntervalSince1970: 0),
                event: .error,
                state: nil,
                captureID: nil,
                errorCode: value,
                metrics: [:]
            )) != nil
    }
}

public enum LocalDiagnosticsHealthLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case unavailable
}

public struct LocalDiagnosticsHealthProjection: Codable, Equatable, Sendable {
    public let energy: LocalDiagnosticsHealthLevel
    public let memory: LocalDiagnosticsHealthLevel
    public let storage: LocalDiagnosticsHealthLevel
    public let indexBacklog: LocalDiagnosticsHealthLevel

    public init(snapshot: LocalDiagnosticsSnapshot) {
        energy =
            switch snapshot.energyCondition {
            case .nominal: .normal
            case .elevated, .constrained: .warning
            case .unavailable: .unavailable
            }
        let memoryBudget = Int64(750 * 1_024 * 1_024)
        memory = snapshot.residentMemoryBytes <= memoryBudget ? .normal : .critical
        let storageBudget = Int64(20 * 1_024 * 1_024 * 1_024)
        if let projection = snapshot.projectedMonthlyStorageBytes {
            storage = projection <= storageBudget ? .normal : .critical
        } else {
            storage = .unavailable
        }
        indexBacklog = snapshot.pendingIndexJobs == 0 ? .normal : .warning
    }
}

public struct LocalDiagnosticExportPreview: Equatable, Sendable {
    public let recordCount: Int
    public let files: [String]
    public let includesCapturedContent: Bool
}

public struct LocalDiagnosticExportResult: Equatable, Sendable {
    public let bundleURL: URL
    public let preview: LocalDiagnosticExportPreview
}

public enum LocalDiagnosticExporter {
    public static func export(
        logger: ContentFreeDiagnosticLogger,
        snapshot: LocalDiagnosticsSnapshot,
        destinationDirectory: URL,
        now: () -> Date = Date.init,
        fileManager: FileManager = .default
    ) throws -> LocalDiagnosticExportResult {
        let destination = destinationDirectory.standardizedFileURL
        let bundle = destination.appending(
            path: "local-memory-diagnostics-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        do {
            if fileManager.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw LocalDiagnosticsError.exportFailed
                }
            }
            let records = try logger.records()
            guard records.count <= 50_000 else { throw LocalDiagnosticsError.invalidLog }
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: bundle,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var events = Data()
            for record in records {
                events.append(try ContentFreeDiagnosticCodec.encoder.encode(record))
                events.append(0x0A)
            }
            let files = ["events.jsonl", "manifest.json", "metrics.json"]
            let manifest = LocalDiagnosticBundleManifest(
                schemaVersion: 1,
                createdAt: now(),
                recordCount: records.count,
                files: files,
                omittedContentClasses: [
                    "pixels", "extractedText", "windowTitles", "urls", "searchQueries",
                    "agentResults", "audio", "transcripts",
                ]
            )
            try write(events, to: bundle.appending(path: files[0]), fileManager: fileManager)
            try write(
                ContentFreeDiagnosticCodec.encoder.encode(manifest),
                to: bundle.appending(path: files[1]),
                fileManager: fileManager
            )
            try write(
                ContentFreeDiagnosticCodec.encoder.encode(snapshot),
                to: bundle.appending(path: files[2]),
                fileManager: fileManager
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: destination.path
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: bundle.path
            )
            return LocalDiagnosticExportResult(
                bundleURL: bundle,
                preview: LocalDiagnosticExportPreview(
                    recordCount: records.count,
                    files: files,
                    includesCapturedContent: false
                )
            )
        } catch {
            if fileManager.fileExists(atPath: bundle.path) {
                try? fileManager.removeItem(at: bundle)
            }
            if error is LocalDiagnosticsError { throw error }
            throw LocalDiagnosticsError.exportFailed
        }
    }

    private static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private struct LocalDiagnosticBundleManifest: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let recordCount: Int
    let files: [String]
    let omittedContentClasses: [String]
}

public enum LocalPerformanceInterval: Sendable {
    case captureAdmission
    case enrichment
    case search
    case diagnosticExport
}

public final class LocalPerformanceSignposter: @unchecked Sendable {
    private let signposter = OSSignposter(
        subsystem: "com.justinhou.deepshelves.localmemory",
        category: "performance"
    )

    public init() {}

    public func measure<T>(
        _ interval: LocalPerformanceInterval,
        operation: () throws -> T
    ) rethrows -> T {
        switch interval {
        case .captureAdmission:
            let state = signposter.beginInterval("CaptureAdmission")
            defer { signposter.endInterval("CaptureAdmission", state) }
            return try operation()
        case .enrichment:
            let state = signposter.beginInterval("Enrichment")
            defer { signposter.endInterval("Enrichment", state) }
            return try operation()
        case .search:
            let state = signposter.beginInterval("Search")
            defer { signposter.endInterval("Search", state) }
            return try operation()
        case .diagnosticExport:
            let state = signposter.beginInterval("DiagnosticExport")
            defer { signposter.endInterval("DiagnosticExport", state) }
            return try operation()
        }
    }

    public func measure<T: Sendable>(
        _ interval: LocalPerformanceInterval,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        switch interval {
        case .captureAdmission:
            let state = signposter.beginInterval("CaptureAdmission")
            defer { signposter.endInterval("CaptureAdmission", state) }
            return try await operation()
        case .enrichment:
            let state = signposter.beginInterval("Enrichment")
            defer { signposter.endInterval("Enrichment", state) }
            return try await operation()
        case .search:
            let state = signposter.beginInterval("Search")
            defer { signposter.endInterval("Search", state) }
            return try await operation()
        case .diagnosticExport:
            let state = signposter.beginInterval("DiagnosticExport")
            defer { signposter.endInterval("DiagnosticExport", state) }
            return try await operation()
        }
    }
}
