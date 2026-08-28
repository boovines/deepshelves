import CryptoKit
import Darwin
import Foundation

public struct ModelResourceArtifact: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String

    public init(relativePath: String, sha256: String) {
        self.relativePath = relativePath
        self.sha256 = sha256
    }
}

public struct ModelResourceManifest: Codable, Equatable, Sendable {
    public let version: String
    public let artifacts: [ModelResourceArtifact]

    public init(version: String, artifacts: [ModelResourceArtifact]) {
        self.version = version
        self.artifacts = artifacts
    }
}

public enum ModelResourceError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case missingArtifact(String)
    case invalidExpectedHash(String)
    case hashMismatch(String)
    case manifestHashMismatch
    case versionMismatch
    case artifactCountMismatch
    case duplicateArtifact(String)
    case unexpectedArtifact(String)
    case symbolicLinkForbidden(String)
    case artifactByteCountMismatch
}

public struct VerifiedModelResources: Equatable, Sendable {
    public let version: String
    public let manifestSHA256: String
    public let artifactCount: Int
    public let bundledFootprintBytes: Int

    public init(
        version: String,
        manifestSHA256: String,
        artifactCount: Int,
        bundledFootprintBytes: Int
    ) {
        self.version = version
        self.manifestSHA256 = manifestSHA256
        self.artifactCount = artifactCount
        self.bundledFootprintBytes = bundledFootprintBytes
    }
}

public enum ModelResourceIntegrity {
    public static func verify(_ manifest: ModelResourceManifest, root: URL) throws {
        for artifact in manifest.artifacts {
            guard isSafeRelativePath(artifact.relativePath) else {
                throw ModelResourceError.invalidRelativePath(artifact.relativePath)
            }
            guard artifact.sha256.count == 64,
                artifact.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw ModelResourceError.invalidExpectedHash(artifact.relativePath)
            }
            let url = root.appending(path: artifact.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ModelResourceError.missingArtifact(artifact.relativePath)
            }
            guard try sha256(of: url) == artifact.sha256 else {
                throw ModelResourceError.hashMismatch(artifact.relativePath)
            }
        }
    }

    public static func verifyBundle(
        root: URL,
        expectedManifestSHA256: String,
        expectedVersion: String,
        expectedArtifactCount: Int,
        expectedBundledFootprintBytes: Int
    ) throws -> VerifiedModelResources {
        let fileManager = FileManager.default
        let normalizedRoot = root.standardizedFileURL
        let rootValues = try normalizedRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rootValues.isSymbolicLink == true {
            throw ModelResourceError.symbolicLinkForbidden(".")
        }

        let manifestURL = normalizedRoot.appending(path: "model-manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ModelResourceError.missingArtifact("model-manifest.json")
        }
        guard try sha256(of: manifestURL) == expectedManifestSHA256 else {
            throw ModelResourceError.manifestHashMismatch
        }

        let manifest: ModelResourceManifest
        do {
            manifest = try JSONDecoder().decode(
                ModelResourceManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw ModelResourceError.manifestHashMismatch
        }
        guard manifest.version == expectedVersion else {
            throw ModelResourceError.versionMismatch
        }
        guard manifest.artifacts.count == expectedArtifactCount else {
            throw ModelResourceError.artifactCountMismatch
        }

        var approvedPaths = Set<String>()
        for artifact in manifest.artifacts {
            guard approvedPaths.insert(artifact.relativePath).inserted else {
                throw ModelResourceError.duplicateArtifact(artifact.relativePath)
            }
        }
        try verify(manifest, root: normalizedRoot)

        let inventory = try fileInventory(root: normalizedRoot)
        let expectedInventory = approvedPaths.union(["model-manifest.json"])
        guard inventory.paths == expectedInventory else {
            let unexpected = inventory.paths.subtracting(expectedInventory).sorted()
            if let first = unexpected.first {
                throw ModelResourceError.unexpectedArtifact(first)
            }
            let missing = expectedInventory.subtracting(inventory.paths).sorted()
            throw ModelResourceError.missingArtifact(missing.first ?? "model-manifest.json")
        }
        guard inventory.totalBytes == expectedBundledFootprintBytes else {
            throw ModelResourceError.artifactByteCountMismatch
        }

        return VerifiedModelResources(
            version: manifest.version,
            manifestSHA256: expectedManifestSHA256,
            artifactCount: manifest.artifacts.count,
            bundledFootprintBytes: inventory.totalBytes
        )
    }

    public static func sha256(of url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { Darwin.close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            autoreleasepool {
                hasher.update(data: Data(buffer.prefix(count)))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func fileInventory(root: URL) throws -> (paths: Set<String>, totalBytes: Int) {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: { _, _ in false }
            )
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let rootPath = root.standardizedFileURL.path + "/"
        var paths = Set<String>()
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPath) else {
                throw ModelResourceError.invalidRelativePath(standardizedPath)
            }
            let relativePath = String(standardizedPath.dropFirst(rootPath.count))
            if values.isSymbolicLink == true {
                throw ModelResourceError.symbolicLinkForbidden(relativePath)
            }
            guard values.isDirectory != true else { continue }
            guard values.isRegularFile == true else {
                throw ModelResourceError.unexpectedArtifact(relativePath)
            }
            paths.insert(relativePath)
            totalBytes += values.fileSize ?? 0
        }
        return (paths, totalBytes)
    }
}
