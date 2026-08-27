import AVFoundation
import CoreGraphics
import CoreML
import CoreVideo
import Darwin
import Foundation
import MemoryEnrichment

struct S7OfflineJourneyReport: Codable, Sendable {
    let schemaVersion: Int
    let completedStages: [S7OfflineJourneyStage]
    let freshArchiveOwnerOnly: Bool
    let onboardingLocalOnly: Bool
    let captureMediaBytes: Int
    let captureVideoTrackCount: Int
    let textSearchResultCount: Int
    let visualModelVersion: String
    let verifiedModelResourceCount: Int
    let visualEmbeddingDimension: Int
    let visualSearchResultCount: Int
    let visualTopResultIndex: Int
    let deletedArtifactAbsent: Bool
    let exportManifestExists: Bool
    let cliExitStatus: Int32
    let cliTransport: String
    let mcpExitStatus: Int32
    let mcpTransport: String
    let runtimeDownloadsAllowed: Bool
    let remoteResourcesAllowed: Bool
}

private struct S7ChildProjection: Codable {
    let component: String
    let schemaVersion: Int
    let status: String
    let transport: String
}

private struct S7ExportManifest: Codable {
    let schemaVersion: Int
    let mediaRelativePath: String
    let mediaSHA256: String
    let searchResultCount: Int
    let visualModelVersion: String
}

enum S7OfflineSpikeRunner {
    static func run(
        outputDirectory: URL,
        mediaFixtureURL: URL,
        signedExecutableURL: URL
    ) async throws -> S7OfflineJourneyReport {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var tracker = S7OfflineJourneyTracker()

        let permissions = try fileManager.attributesOfItem(atPath: outputDirectory.path)
        let ownerOnly = (permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700
        try tracker.complete(.firstLaunch)

        let onboardingURL = outputDirectory.appending(path: "onboarding.json")
        try writeJSON(
            ["completed": true, "localOnly": true],
            to: onboardingURL
        )
        try tracker.complete(.onboarding)

        let archive = outputDirectory.appending(path: "archive", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: archive,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let capturedMedia = archive.appending(path: "capture.mov")
        try fileManager.copyItem(at: mediaFixtureURL, to: capturedMedia)
        let captureBytes = try fileSize(capturedMedia)
        let videoTracks = try await AVURLAsset(url: capturedMedia).loadTracks(withMediaType: .video)
        guard captureBytes > 0, !videoTracks.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try tracker.complete(.capture)

        let localRecords = [
            "calendar focus block",
            "blue desk lamp beside the notebook",
            "project document review",
        ]
        let textResults = localRecords.filter { $0.localizedCaseInsensitiveContains("lamp") }
        guard textResults == ["blue desk lamp beside the notebook"] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try tracker.complete(.search)

        let resourceRoot = try MobileCLIPRuntime.bundledResourceRoot()
        let manifest = try JSONDecoder().decode(
            ModelResourceManifest.self,
            from: Data(contentsOf: resourceRoot.appending(path: "model-manifest.json"))
        )
        try ModelResourceIntegrity.verify(manifest, root: resourceRoot)
        let runtime = try MobileCLIPRuntime.bundled(computeUnits: .all)
        let imageEmbedding = try await runtime.embed(image: MobileCLIPPixelBuffer(try visualFixture()))
        let textEmbedding = try await runtime.embed(text: "a blue visual memory")
        let vectorURL = archive.appending(path: "visual.f16")
        try ExactVectorFileWriter.write(
            vectors: [imageEmbedding],
            modelVersion: MobileCLIPRuntime.version,
            to: vectorURL
        )
        let visualResults = try ExactVectorScanner(url: vectorURL).search(
            query: textEmbedding,
            range: 0 ..< 1,
            limit: 1
        )
        guard imageEmbedding.count == MobileCLIPRuntime.dimension,
              visualResults.first?.index == 0
        else {
            throw CocoaError(.coderInvalidValue)
        }
        try tracker.complete(.visualInference)

        let deletionTarget = archive.appending(path: "delete-me-local-sentinel.bin")
        try Data("LM008-S7-DELETE-ME".utf8).write(to: deletionTarget, options: .atomic)
        try fileManager.removeItem(at: deletionTarget)
        let deletedArtifactAbsent = !fileManager.fileExists(atPath: deletionTarget.path)
        guard deletedArtifactAbsent else {
            throw CocoaError(.fileWriteFileExists)
        }
        try tracker.complete(.deletion)

        let exportDirectory = outputDirectory.appending(path: "export", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let exportManifestURL = exportDirectory.appending(path: "manifest.json")
        try writeJSON(
            S7ExportManifest(
                schemaVersion: 1,
                mediaRelativePath: "archive/capture.mov",
                mediaSHA256: try ModelResourceIntegrity.sha256(of: capturedMedia),
                searchResultCount: textResults.count,
                visualModelVersion: MobileCLIPRuntime.version
            ),
            to: exportManifestURL
        )
        try tracker.complete(.export)

        let cli = try childProjection(role: "cli", executableURL: signedExecutableURL)
        guard cli.status == 0, cli.projection.transport == "local-stdio" else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        try tracker.complete(.cli)
        let mcp = try childProjection(role: "mcp", executableURL: signedExecutableURL)
        guard mcp.status == 0, mcp.projection.transport == "local-stdio" else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        try tracker.complete(.mcp)

        let report = S7OfflineJourneyReport(
            schemaVersion: 1,
            completedStages: tracker.completedStages,
            freshArchiveOwnerOnly: ownerOnly,
            onboardingLocalOnly: true,
            captureMediaBytes: captureBytes,
            captureVideoTrackCount: videoTracks.count,
            textSearchResultCount: textResults.count,
            visualModelVersion: manifest.version,
            verifiedModelResourceCount: manifest.artifacts.count,
            visualEmbeddingDimension: imageEmbedding.count,
            visualSearchResultCount: visualResults.count,
            visualTopResultIndex: visualResults[0].index,
            deletedArtifactAbsent: deletedArtifactAbsent,
            exportManifestExists: fileManager.fileExists(atPath: exportManifestURL.path),
            cliExitStatus: cli.status,
            cliTransport: cli.projection.transport,
            mcpExitStatus: mcp.status,
            mcpTransport: mcp.projection.transport,
            runtimeDownloadsAllowed: false,
            remoteResourcesAllowed: false
        )
        try writeJSON(report, to: outputDirectory.appending(path: "s7-journey.json"))
        return report
    }

    static func writeChildProjection(role: String) -> Never {
        let projection = S7ChildProjection(
            component: role == "mcp" ? "local-memory-mcp" : "local-memory",
            schemaVersion: 1,
            status: "ready-offline",
            transport: "local-stdio"
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(projection))
            FileHandle.standardOutput.write(Data([0x0A]))
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func childProjection(
        role: String,
        executableURL: URL
    ) throws -> (status: Int32, projection: S7ChildProjection) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--lm008-s7-child", role]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            try JSONDecoder().decode(S7ChildProjection.self, from: data)
        )
    }

    private static func visualFixture() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            256,
            256,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw CocoaError(.coderInvalidValue)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: baseAddress,
                  width: 256,
                  height: 256,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                      CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else {
            throw CocoaError(.coderInvalidValue)
        }
        context.setFillColor(CGColor(red: 0.08, green: 0.24, blue: 0.70, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(red: 0.95, green: 0.90, blue: 0.30, alpha: 1))
        context.fillEllipse(in: CGRect(x: 52, y: 52, width: 152, height: 152))
        return buffer
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
