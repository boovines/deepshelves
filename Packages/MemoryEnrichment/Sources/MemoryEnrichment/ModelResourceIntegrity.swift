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
}
