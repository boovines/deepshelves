import Foundation

public struct LM018BoundaryFaultResult: Codable, Equatable, Sendable {
    public let boundary: String
    public let partialPresentBeforeRecovery: Bool
    public let finalPresentBeforeRecovery: Bool
    public let removedPartialFiles: Int
    public let quarantinedOrphanFiles: Int
    public let searchableFramesAfterRecovery: Int
    public let invariantPassed: Bool
}

public struct LM018IntegrityFaultResult: Codable, Equatable, Sendable {
    public let caseName: String
    public let quarantinedCorruptFiles: Int
    public let missingReadyFiles: Int
    public let searchableFramesAfterRecovery: Int
    public let finalState: String
    public let invariantPassed: Bool
}

public struct LM018FaultReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedFrom: String
    public let boundaries: [LM018BoundaryFaultResult]
    public let integrityCases: [LM018IntegrityFaultResult]
    public let requeuedLeasedJobs: Int
    public let pathTraversalRejected: Bool
    public let ownerOnlyDirectories: Bool
    public let ownerOnlyFiles: Bool
    public let allInvariantsPassed: Bool
}

public enum LM018FaultHarnessError: Error, Equatable, Sendable {
    case expectedFaultDidNotOccur(String)
    case recoveryInvariantFailed
}

public enum LM018FaultHarness: Sendable {
    public static func run() throws -> LM018FaultReport {
        let beforeRename = try runBoundary(.beforeRename)
        let afterRename = try runBoundary(.afterRenameBeforeCommit)
        let hashMismatch = try runHashMismatch()
        let missing = try runMissingAndLease()
        let permissionResult = try runPermissionFixture()
        let traversalRejected = (try? ArchiveRelativePath("../outside.mov")) == nil
        let boundaries = [beforeRename, afterRename]
        let integrityCases = [hashMismatch.result, missing.result]
        let allPassed = boundaries.allSatisfy(\.invariantPassed) &&
            integrityCases.allSatisfy(\.invariantPassed) &&
            missing.requeuedLeasedJobs == 1 &&
            traversalRejected &&
            permissionResult.directories &&
            permissionResult.files
        guard allPassed else {
            throw LM018FaultHarnessError.recoveryInvariantFailed
        }
        return LM018FaultReport(
            schemaVersion: 1,
            generatedFrom: "MemoryStore production atomic writer and startup recovery",
            boundaries: boundaries,
            integrityCases: integrityCases,
            requeuedLeasedJobs: missing.requeuedLeasedJobs,
            pathTraversalRejected: traversalRejected,
            ownerOnlyDirectories: permissionResult.directories,
            ownerOnlyFiles: permissionResult.files,
            allInvariantsPassed: allPassed
        )
    }

    private static func runBoundary(
        _ boundary: ArchiveWriteBoundary
    ) throws -> LM018BoundaryFaultResult {
        let fixture = try Fixture(name: boundary.rawValue)
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        guard let store = archive.fileStore else {
            throw LM018FaultHarnessError.recoveryInvariantFailed
        }
        let path = try ArchiveRelativePath("media/2026/08/28/\(boundary.rawValue).mov")
        do {
            try store.write(Data("synthetic approved fixture".utf8), to: path, fault: boundary)
            throw LM018FaultHarnessError.expectedFaultDidNotOccur(boundary.rawValue)
        } catch let error as ArchiveFileStoreError {
            guard error == .injectedFault(boundary) else { throw error }
        }
        let partialBefore = FileManager.default.fileExists(atPath: store.partialURL(for: path).path)
        let finalBefore = FileManager.default.fileExists(atPath: store.url(for: path).path)
        let recovered = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let searchable = try recovered.searchableFrameCountForTesting()
        let passed: Bool
        switch boundary {
        case .beforeRename:
            passed = partialBefore && !finalBefore &&
                recovered.startupRecoveryReport.removedPartialFiles == 1 &&
                recovered.startupRecoveryReport.quarantinedOrphanFiles == 0 &&
                searchable == 0
        case .afterRenameBeforeCommit:
            passed = !partialBefore && finalBefore &&
                recovered.startupRecoveryReport.removedPartialFiles == 0 &&
                recovered.startupRecoveryReport.quarantinedOrphanFiles == 1 &&
                searchable == 0
        }
        return LM018BoundaryFaultResult(
            boundary: boundary.rawValue,
            partialPresentBeforeRecovery: partialBefore,
            finalPresentBeforeRecovery: finalBefore,
            removedPartialFiles: recovered.startupRecoveryReport.removedPartialFiles,
            quarantinedOrphanFiles: recovered.startupRecoveryReport.quarantinedOrphanFiles,
            searchableFramesAfterRecovery: searchable,
            invariantPassed: passed
        )
    }

    private static func runHashMismatch() throws -> (
        result: LM018IntegrityFaultResult,
        report: ArchiveStartupRecoveryReport
    ) {
        let fixture = try Fixture(name: "hash-mismatch")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        guard let store = archive.fileStore else {
            throw LM018FaultHarnessError.recoveryInvariantFailed
        }
        let path = try ArchiveRelativePath("media/2026/08/28/hash-mismatch.mov")
        try store.write(Data("original".utf8), to: path) { integrity in
            try archive.insertReadyMediaFixtureForTesting(
                chunkID: "hash-mismatch-chunk",
                frameID: "hash-mismatch-frame",
                integrity: integrity
            )
        }
        try Data("tampered".utf8).write(to: store.url(for: path))
        let recovered = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let searchable = try recovered.searchableFrameCountForTesting()
        let state = try recovered.mediaChunkStateForTesting(id: "hash-mismatch-chunk") ?? "missing"
        return (
            LM018IntegrityFaultResult(
                caseName: "sha256-mismatch",
                quarantinedCorruptFiles: recovered.startupRecoveryReport.quarantinedCorruptFiles,
                missingReadyFiles: recovered.startupRecoveryReport.missingReadyFiles,
                searchableFramesAfterRecovery: searchable,
                finalState: state,
                invariantPassed: recovered.startupRecoveryReport.quarantinedCorruptFiles == 1 &&
                    state == "quarantined" && searchable == 0
            ),
            recovered.startupRecoveryReport
        )
    }

    private static func runMissingAndLease() throws -> (
        result: LM018IntegrityFaultResult,
        requeuedLeasedJobs: Int
    ) {
        let fixture = try Fixture(name: "missing")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let path = try ArchiveRelativePath("media/2026/08/28/missing.mov")
        try archive.insertMissingReadyMediaFixtureForTesting(
            chunkID: "missing-chunk",
            frameID: "missing-frame",
            relativePath: path
        )
        try archive.insertLeasedJobFixtureForTesting(id: "leased-job")
        let recovered = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let searchable = try recovered.searchableFrameCountForTesting()
        let state = try recovered.mediaChunkStateForTesting(id: "missing-chunk") ?? "missing"
        let jobState = try recovered.processingJobStateForTesting(id: "leased-job")
        return (
            LM018IntegrityFaultResult(
                caseName: "missing-ready-file",
                quarantinedCorruptFiles: recovered.startupRecoveryReport.quarantinedCorruptFiles,
                missingReadyFiles: recovered.startupRecoveryReport.missingReadyFiles,
                searchableFramesAfterRecovery: searchable,
                finalState: state,
                invariantPassed: recovered.startupRecoveryReport.missingReadyFiles == 1 &&
                    state == "quarantined" && searchable == 0 && jobState == "queued"
            ),
            recovered.startupRecoveryReport.requeuedLeasedJobs
        )
    }

    private static func runPermissionFixture() throws -> (directories: Bool, files: Bool) {
        let fixture = try Fixture(name: "permissions")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let nestedDirectory = paths.exports.appending(path: "fixture", directoryHint: .isDirectory)
        let file = nestedDirectory.appending(path: "report.json")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nestedDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        return (
            try permissions(of: nestedDirectory) == ArchivePathProvider.directoryPermissions,
            try permissions(of: file) == ArchivePathProvider.filePermissions
        )
    }

    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private struct Fixture {
        let root: URL
        let applicationSupport: URL

        init(name: String) throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "lm018-harness-\(name)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            applicationSupport = root.appending(
                path: "Application Support",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: applicationSupport,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
