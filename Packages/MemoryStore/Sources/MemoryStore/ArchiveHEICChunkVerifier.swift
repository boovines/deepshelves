import CryptoKit
import Foundation
import MemoryContracts

public enum ArchiveHEICVerificationError: Error, Equatable, Sendable {
    case invalidManifestPath
    case missingManifest
    case nonDirectoryChunk
    case symbolicLinkForbidden
    case manifestInvalid
    case chunkIdentityMismatch
    case captureIdentityMismatch
    case inventoryMismatch
    case frameIntegrityMismatch
}

public struct ArchiveVerifiedHEICFrame: Equatable, Sendable {
    public let id: UUID
    public let presentationTimeMilliseconds: Int64
    public let archiveRelativePath: String
    public let byteCount: Int64
    public let sha256: Data
}

public struct ArchiveVerifiedHEICChunk: Equatable, Sendable {
    public let manifest: HEICKeyframeManifest
    public let manifestRelativePath: ArchiveRelativePath
    public let manifestByteCount: Int64
    public let totalByteCount: Int64
    public let manifestSHA256: Data
    public let frames: [ArchiveVerifiedHEICFrame]
}

public enum ArchiveHEICChunkVerifier {
    public static func verify(
        paths: ArchivePaths,
        manifestRelativePath: ArchiveRelativePath,
        expectedChunkID: UUID? = nil,
        expectedCaptureEpochID: UUID? = nil,
        expectedTargetWindowID: UInt32? = nil,
        fileManager: FileManager = .default
    ) throws -> ArchiveVerifiedHEICChunk {
        let relativeComponents = manifestRelativePath.rawValue.split(separator: "/").map(
            String.init)
        guard relativeComponents.count >= 6,
            relativeComponents.first == "media",
            relativeComponents.suffix(1) == ["manifest.json"],
            let encodedChunkID = relativeComponents.dropLast().last,
            UUID(uuidString: encodedChunkID) != nil,
            encodedChunkID == encodedChunkID.lowercased(),
            !relativeComponents.contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".partial") })
        else {
            throw ArchiveHEICVerificationError.invalidManifestPath
        }

        let manifestURL = paths.root.appending(
            path: manifestRelativePath.rawValue,
            directoryHint: .notDirectory
        )
        let chunkDirectory = manifestURL.deletingLastPathComponent()
        let standardizedRoot = paths.root.standardizedFileURL.path
        guard chunkDirectory.standardizedFileURL.path.hasPrefix(standardizedRoot + "/") else {
            throw ArchiveHEICVerificationError.invalidManifestPath
        }
        let directoryValues = try chunkDirectory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true else {
            throw ArchiveHEICVerificationError.nonDirectoryChunk
        }
        guard directoryValues.isSymbolicLink != true else {
            throw ArchiveHEICVerificationError.symbolicLinkForbidden
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ArchiveHEICVerificationError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: HEICKeyframeManifest
        do {
            manifest = try ContractJSON.decode(HEICKeyframeManifest.self, from: manifestData)
        } catch {
            throw ArchiveHEICVerificationError.manifestInvalid
        }
        guard manifest.chunkID.uuidString.lowercased() == encodedChunkID,
            expectedChunkID == nil || manifest.chunkID == expectedChunkID
        else {
            throw ArchiveHEICVerificationError.chunkIdentityMismatch
        }
        guard expectedCaptureEpochID == nil || manifest.captureEpochID == expectedCaptureEpochID,
            expectedTargetWindowID == nil || manifest.targetWindowID == expectedTargetWindowID
        else {
            throw ArchiveHEICVerificationError.captureIdentityMismatch
        }

        let expectedFiles = Set(["manifest.json"] + manifest.frames.map(\.relativePath))
        guard
            let enumerator = fileManager.enumerator(
                at: chunkDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: []
            )
        else {
            throw ArchiveHEICVerificationError.inventoryMismatch
        }
        let baseComponents = chunkDirectory.standardizedFileURL.pathComponents
        var actualFiles: Set<String> = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ArchiveHEICVerificationError.symbolicLinkForbidden
            }
            let itemComponents = item.standardizedFileURL.pathComponents
            guard itemComponents.starts(with: baseComponents) else {
                throw ArchiveHEICVerificationError.symbolicLinkForbidden
            }
            let relative = itemComponents.dropFirst(baseComponents.count).joined(separator: "/")
            if values.isRegularFile == true {
                actualFiles.insert(relative)
            } else if values.isDirectory != true {
                throw ArchiveHEICVerificationError.inventoryMismatch
            }
        }
        guard actualFiles == expectedFiles else {
            throw ArchiveHEICVerificationError.inventoryMismatch
        }

        let parentRelativePath = relativeComponents.dropLast().joined(separator: "/")
        var verifiedFrames: [ArchiveVerifiedHEICFrame] = []
        var totalByteCount = Int64(manifestData.count)
        for entry in manifest.frames {
            let frameURL = chunkDirectory.appending(
                path: entry.relativePath,
                directoryHint: .notDirectory
            )
            let values = try frameURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                Int64(values.fileSize ?? -1) == entry.byteCount,
                Data(SHA256.hash(data: try Data(contentsOf: frameURL))) == entry.sha256
            else {
                throw ArchiveHEICVerificationError.frameIntegrityMismatch
            }
            totalByteCount += entry.byteCount
            verifiedFrames.append(
                ArchiveVerifiedHEICFrame(
                    id: entry.frameID,
                    presentationTimeMilliseconds: entry.presentationTimeMS,
                    archiveRelativePath: "\(parentRelativePath)/\(entry.relativePath)",
                    byteCount: entry.byteCount,
                    sha256: entry.sha256
                )
            )
        }
        return ArchiveVerifiedHEICChunk(
            manifest: manifest,
            manifestRelativePath: manifestRelativePath,
            manifestByteCount: Int64(manifestData.count),
            totalByteCount: totalByteCount,
            manifestSHA256: Data(SHA256.hash(data: manifestData)),
            frames: verifiedFrames
        )
    }
}
