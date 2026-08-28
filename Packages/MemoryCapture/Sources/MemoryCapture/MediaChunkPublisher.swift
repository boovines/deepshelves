import CryptoKit
import Darwin
import Foundation

public struct PublishedMediaIntegrity: Equatable, Sendable {
    public let byteCount: Int64
    public let sha256: Data

    public var sha256Hex: String {
        sha256.map { String(format: "%02x", $0) }.joined()
    }
}

public enum MediaPublishFault: String, Equatable, Sendable {
    case beforeRename
    case afterRenameBeforeDirectorySync
}

public enum MediaChunkPublisherError: Error, Equatable, Sendable {
    case destinationAlreadyExists
    case partialMissing
    case symbolicLinkForbidden
    case nonRegularPartial
    case emptyPartial
    case renameFailed(Int32)
    case directorySyncFailed(Int32)
    case injectedFault(MediaPublishFault)
}

public enum MediaChunkPublisher {
    public static func partialURL(for outputURL: URL) -> URL {
        outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).partial.mov"
        )
    }

    public static func publish(
        partialURL: URL,
        outputURL: URL,
        fault: MediaPublishFault? = nil
    ) throws -> PublishedMediaIntegrity {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw MediaChunkPublisherError.destinationAlreadyExists
        }
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw MediaChunkPublisherError.partialMissing
        }
        let values = try partialURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw MediaChunkPublisherError.symbolicLinkForbidden
        }
        guard values.isRegularFile == true else {
            throw MediaChunkPublisherError.nonRegularPartial
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: partialURL.path
        )
        try synchronizeFile(at: partialURL)
        let integrity = try integrity(of: partialURL)
        guard integrity.byteCount > 0 else {
            throw MediaChunkPublisherError.emptyPartial
        }
        if fault == .beforeRename {
            throw MediaChunkPublisherError.injectedFault(.beforeRename)
        }

        let renameStatus = partialURL.path.withCString { source in
            outputURL.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renameStatus == 0 else {
            if errno == EEXIST {
                throw MediaChunkPublisherError.destinationAlreadyExists
            }
            throw MediaChunkPublisherError.renameFailed(errno)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outputURL.path
        )
        if fault == .afterRenameBeforeDirectorySync {
            throw MediaChunkPublisherError.injectedFault(.afterRenameBeforeDirectorySync)
        }
        try synchronizeDirectory(at: outputURL.deletingLastPathComponent())
        return integrity
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MediaChunkPublisherError.directorySyncFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MediaChunkPublisherError.directorySyncFailed(errno)
        }
    }

    private static func integrity(of url: URL) throws -> PublishedMediaIntegrity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = Int64(attributes[.size] as? UInt64 ?? 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return PublishedMediaIntegrity(
            byteCount: byteCount,
            sha256: Data(hasher.finalize())
        )
    }
}
