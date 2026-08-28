import CoreVideo
import CryptoKit
import Darwin
import Foundation
import MemoryContracts

public protocol HEICFrameEncoding: Sendable {
    func encode(
        _ source: CVPixelBuffer,
        destinationDimensions: PixelSize
    ) throws -> Data
}

public enum HEICFrameEncoderError: Error, Equatable, Sendable {
    case unsupportedPixelFormat
    case pixelBufferUnavailable
    case emptyPayload
    case runtimeQuarantined
}

public struct QuarantinedHEICFrameEncoder: HEICFrameEncoding {
    public init() {}

    public func encode(
        _ source: CVPixelBuffer,
        destinationDimensions: PixelSize
    ) throws -> Data {
        throw HEICFrameEncoderError.runtimeQuarantined
    }
}

public enum HEICKeyframeWriterError: Error, Equatable, Sendable {
    case invalidDimensions
    case destinationAlreadyExists
    case stagingAlreadyExists
    case scopeMismatch
    case invalidPresentationTime
    case nonIncreasingPresentationTime
    case maximumDurationExceeded
    case emptyEncodedFrame
    case frameAlreadyExists
    case alreadyFinalized
    case manifestMismatch
    case chunkIdentityMismatch
    case inventoryMismatch(expected: [String], actual: [String])
    case frameIntegrityMismatch
}

public final class HEICKeyframeWriter: @unchecked Sendable {
    public let outputDirectoryURL: URL
    public let stagingDirectoryURL: URL
    public let chunkID: UUID
    public let scope: MediaChunkScope

    private let encoder: any HEICFrameEncoding
    private var core: MediaWriterCore
    private var entries: [HEICKeyframeEntry] = []
    private var finalized = false

    public init(
        outputDirectoryURL: URL,
        chunkID: UUID = UUID(),
        scope: MediaChunkScope,
        encoder: any HEICFrameEncoding
    ) throws {
        guard scope.dimensions.width >= 2, scope.dimensions.height >= 2,
            scope.dimensions.width.isMultiple(of: 2),
            scope.dimensions.height.isMultiple(of: 2),
            max(scope.dimensions.width, scope.dimensions.height)
                <= CaptureConstants.maximumLongEdge
        else {
            throw HEICKeyframeWriterError.invalidDimensions
        }
        self.outputDirectoryURL = outputDirectoryURL
        self.chunkID = chunkID
        self.scope = scope
        self.encoder = encoder
        core = try MediaWriterCore(chunkID: chunkID, scope: scope)
        stagingDirectoryURL = outputDirectoryURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputDirectoryURL.lastPathComponent).partial",
            isDirectory: true
        )

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputDirectoryURL.path) else {
            throw HEICKeyframeWriterError.destinationAlreadyExists
        }
        guard !fileManager.fileExists(atPath: stagingDirectoryURL.path) else {
            throw HEICKeyframeWriterError.stagingAlreadyExists
        }
        try fileManager.createDirectory(
            at: outputDirectoryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: stagingDirectoryURL.appendingPathComponent("frames", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stagingDirectoryURL.path
        )
    }

    @discardableResult
    public func append(
        _ source: CVPixelBuffer,
        frameID: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        sourcePresentationTimeMilliseconds: Int64
    ) throws -> MediaFrameLocator {
        guard !finalized else {
            throw HEICKeyframeWriterError.alreadyFinalized
        }
        let sourceDimensions = PixelSize(
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source)
        )
        let plan: MediaWriterAppendPlan
        do {
            plan = try core.planAppend(
                frameID: frameID,
                captureEpochID: captureEpochID,
                targetWindowID: targetWindowID,
                sourceDimensions: sourceDimensions,
                sourcePresentationTimeMilliseconds: sourcePresentationTimeMilliseconds
            )
        } catch let error as MediaWriterCoreError {
            throw Self.writerError(for: error)
        }

        let data = try encoder.encode(
            source,
            destinationDimensions: plan.downscale.destinationDimensions
        )
        guard !data.isEmpty else {
            throw HEICKeyframeWriterError.emptyEncodedFrame
        }
        let relativePath = plan.locator.frameRelativePath
        let destination = stagingDirectoryURL.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw HEICKeyframeWriterError.frameAlreadyExists
        }
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).partial"
        )
        try DurableMediaFiles.writeAndPublishFile(
            data,
            partialURL: partial,
            outputURL: destination
        )

        do {
            try core.recordAccepted(plan)
            entries.append(
                try HEICKeyframeEntry(
                    frameID: frameID,
                    presentationTimeMS: plan.locator.presentationTimeMilliseconds,
                    relativePath: relativePath,
                    byteCount: Int64(data.count),
                    sha256: Data(SHA256.hash(data: data))
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return plan.locator
    }

    public func finish(
        fault: MediaPublishFault? = nil
    ) throws -> HEICMediaChunkFinalization? {
        guard !finalized else {
            throw HEICKeyframeWriterError.alreadyFinalized
        }
        finalized = true
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: stagingDirectoryURL)
            return nil
        }
        let manifest = try HEICKeyframeManifest(
            chunkID: chunkID,
            captureEpochID: scope.epochID,
            targetWindowID: scope.targetWindowID,
            width: scope.dimensions.width,
            height: scope.dimensions.height,
            frames: entries
        )
        let manifestData = try ContractJSON.encode(manifest)
        let manifestURL = stagingDirectoryURL.appendingPathComponent("manifest.json")
        let partialManifestURL = stagingDirectoryURL.appendingPathComponent(
            ".manifest.json.partial")
        try DurableMediaFiles.writeAndPublishFile(
            manifestData,
            partialURL: partialManifestURL,
            outputURL: manifestURL
        )
        let published = try HEICKeyframeChunkPublisher.publish(
            stagingDirectoryURL: stagingDirectoryURL,
            outputDirectoryURL: outputDirectoryURL,
            expectedChunkID: chunkID,
            fault: fault
        )
        guard published.manifest == manifest else {
            throw HEICKeyframeWriterError.manifestMismatch
        }
        return try core.heicFinalization(
            outputDirectoryURL: outputDirectoryURL,
            manifest: manifest,
            integrity: published.integrity
        )
    }

    public func cancel() {
        guard !finalized else { return }
        finalized = true
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    deinit {
        guard !finalized else { return }
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    private static func writerError(for error: MediaWriterCoreError) -> HEICKeyframeWriterError {
        switch error {
        case .invalidDestinationDimensions, .invalidSourceDimensions, .aspectRatioMismatch,
            .upscalingForbidden:
            .invalidDimensions
        case .scopeMismatch:
            .scopeMismatch
        case .invalidPresentationTime:
            .invalidPresentationTime
        case .nonIncreasingPresentationTime:
            .nonIncreasingPresentationTime
        case .maximumDurationExceeded:
            .maximumDurationExceeded
        case .staleAppendPlan, .emptyChunk:
            .manifestMismatch
        }
    }
}

public struct PublishedHEICKeyframeChunk: Equatable, Sendable {
    public let manifest: HEICKeyframeManifest
    public let integrity: PublishedMediaIntegrity
}

public enum HEICKeyframeChunkPublisher {
    public static func publish(
        stagingDirectoryURL: URL,
        outputDirectoryURL: URL,
        expectedChunkID: UUID,
        fault: MediaPublishFault? = nil
    ) throws -> PublishedHEICKeyframeChunk {
        _ = try verify(
            directoryURL: stagingDirectoryURL,
            expectedChunkID: expectedChunkID
        )
        if fault == .beforeRename {
            throw MediaChunkPublisherError.injectedFault(.beforeRename)
        }
        let renameStatus = stagingDirectoryURL.path.withCString { source in
            outputDirectoryURL.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renameStatus == 0 else {
            if errno == EEXIST {
                throw MediaChunkPublisherError.destinationAlreadyExists
            }
            throw MediaChunkPublisherError.renameFailed(errno)
        }
        let postRename = try verify(
            directoryURL: outputDirectoryURL,
            expectedChunkID: expectedChunkID
        )
        if fault == .afterRenameBeforeDirectorySync {
            throw MediaChunkPublisherError.injectedFault(.afterRenameBeforeDirectorySync)
        }
        try DurableMediaFiles.synchronizeDirectory(
            at: outputDirectoryURL.deletingLastPathComponent())
        return postRename
    }

    public static func verify(
        directoryURL: URL,
        expectedChunkID: UUID
    ) throws -> PublishedHEICKeyframeChunk {
        let fileManager = FileManager.default
        let directoryValues = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw MediaChunkPublisherError.nonRegularPartial
        }
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ContractJSON.decode(HEICKeyframeManifest.self, from: manifestData)
        guard manifest.chunkID == expectedChunkID else {
            throw HEICKeyframeWriterError.chunkIdentityMismatch
        }

        let expectedPaths = Set(
            ["manifest.json"] + manifest.frames.map(\.relativePath)
        )
        guard
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ],
                options: []
            )
        else {
            throw MediaChunkPublisherError.nonRegularPartial
        }
        var actualPaths: Set<String> = []
        let baseComponents = directoryURL.standardizedFileURL.pathComponents
        for case let item as URL in enumerator {
            let itemComponents = item.standardizedFileURL.pathComponents
            guard itemComponents.starts(with: baseComponents) else {
                throw MediaChunkPublisherError.symbolicLinkForbidden
            }
            let relative = itemComponents.dropFirst(baseComponents.count).joined(separator: "/")
            let values = try item.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw MediaChunkPublisherError.symbolicLinkForbidden
            }
            if values.isRegularFile == true {
                actualPaths.insert(relative)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: item.path
                )
            } else if values.isDirectory == true {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: item.path
                )
            } else {
                throw MediaChunkPublisherError.nonRegularPartial
            }
        }
        guard actualPaths == expectedPaths else {
            throw HEICKeyframeWriterError.inventoryMismatch(
                expected: expectedPaths.sorted(),
                actual: actualPaths.sorted()
            )
        }

        var totalByteCount = Int64(manifestData.count)
        for entry in manifest.frames {
            let asset = directoryURL.appendingPathComponent(entry.relativePath)
            let data = try Data(contentsOf: asset)
            guard Int64(data.count) == entry.byteCount,
                Data(SHA256.hash(data: data)) == entry.sha256
            else {
                throw HEICKeyframeWriterError.frameIntegrityMismatch
            }
            totalByteCount += entry.byteCount
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try DurableMediaFiles.synchronizeDirectory(
            at: directoryURL.appendingPathComponent("frames", isDirectory: true))
        try DurableMediaFiles.synchronizeDirectory(at: directoryURL)
        return PublishedHEICKeyframeChunk(
            manifest: manifest,
            integrity: PublishedMediaIntegrity(
                byteCount: totalByteCount,
                sha256: Data(SHA256.hash(data: manifestData))
            )
        )
    }
}

public enum HEICKeyframeChunkRewriter {
    public static func republish(
        sourceDirectoryURL: URL,
        outputDirectoryURL: URL,
        replacementChunkID: UUID,
        retaining frameIDs: Set<UUID>,
        fault: MediaPublishFault? = nil
    ) throws -> PublishedHEICKeyframeChunk {
        let sourceManifestData = try Data(
            contentsOf: sourceDirectoryURL.appendingPathComponent("manifest.json"))
        let sourceManifest = try ContractJSON.decode(
            HEICKeyframeManifest.self,
            from: sourceManifestData
        )
        _ = try HEICKeyframeChunkPublisher.verify(
            directoryURL: sourceDirectoryURL,
            expectedChunkID: sourceManifest.chunkID
        )
        let retained = sourceManifest.frames.filter { frameIDs.contains($0.frameID) }
        guard !retained.isEmpty, Set(retained.map(\.frameID)) == frameIDs else {
            throw HEICKeyframeWriterError.manifestMismatch
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputDirectoryURL.path) else {
            throw HEICKeyframeWriterError.destinationAlreadyExists
        }
        let staging = outputDirectoryURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputDirectoryURL.lastPathComponent).partial",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: staging.path) else {
            throw HEICKeyframeWriterError.stagingAlreadyExists
        }
        try fileManager.createDirectory(
            at: staging.appendingPathComponent("frames", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: staging.path
        )

        do {
            let firstTime = retained[0].presentationTimeMS
            var replacementEntries: [HEICKeyframeEntry] = []
            for entry in retained {
                let data = try Data(
                    contentsOf: sourceDirectoryURL.appendingPathComponent(entry.relativePath))
                let destination = staging.appendingPathComponent(entry.relativePath)
                let partial = destination.deletingLastPathComponent().appendingPathComponent(
                    ".\(destination.lastPathComponent).partial"
                )
                try DurableMediaFiles.writeAndPublishFile(
                    data,
                    partialURL: partial,
                    outputURL: destination
                )
                replacementEntries.append(
                    try HEICKeyframeEntry(
                        frameID: entry.frameID,
                        presentationTimeMS: entry.presentationTimeMS - firstTime,
                        relativePath: entry.relativePath,
                        byteCount: entry.byteCount,
                        sha256: entry.sha256
                    )
                )
            }
            let replacementManifest = try HEICKeyframeManifest(
                chunkID: replacementChunkID,
                captureEpochID: sourceManifest.captureEpochID,
                targetWindowID: sourceManifest.targetWindowID,
                width: sourceManifest.width,
                height: sourceManifest.height,
                frames: replacementEntries
            )
            let manifestData = try ContractJSON.encode(replacementManifest)
            try DurableMediaFiles.writeAndPublishFile(
                manifestData,
                partialURL: staging.appendingPathComponent(".manifest.json.partial"),
                outputURL: staging.appendingPathComponent("manifest.json")
            )
            return try HEICKeyframeChunkPublisher.publish(
                stagingDirectoryURL: staging,
                outputDirectoryURL: outputDirectoryURL,
                expectedChunkID: replacementChunkID,
                fault: fault
            )
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }

    public static func removeRetiredDirectory(
        _ directoryURL: URL,
        expectedChunkID: UUID
    ) throws {
        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true,
            directoryURL.lastPathComponent == expectedChunkID.uuidString.lowercased()
        else {
            throw HEICKeyframeWriterError.chunkIdentityMismatch
        }
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? ContractJSON.decode(HEICKeyframeManifest.self, from: data),
            manifest.chunkID != expectedChunkID
        {
            throw HEICKeyframeWriterError.chunkIdentityMismatch
        }
        try FileManager.default.removeItem(at: directoryURL)
        try DurableMediaFiles.synchronizeDirectory(
            at: directoryURL.deletingLastPathComponent())
    }
}

enum DurableMediaFiles {
    static func writeAndPublishFile(
        _ data: Data,
        partialURL: URL,
        outputURL: URL
    ) throws {
        guard !data.isEmpty else {
            throw HEICFrameEncoderError.emptyPayload
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw HEICKeyframeWriterError.frameAlreadyExists
        }
        try data.write(to: partialURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: partialURL.path
        )
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.synchronize()
        try handle.close()
        let status = partialURL.path.withCString { source in
            outputURL.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            if errno == EEXIST {
                throw HEICKeyframeWriterError.frameAlreadyExists
            }
            throw MediaChunkPublisherError.renameFailed(errno)
        }
        try synchronizeDirectory(at: outputURL.deletingLastPathComponent())
    }

    static func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MediaChunkPublisherError.directorySyncFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MediaChunkPublisherError.directorySyncFailed(errno)
        }
    }
}
