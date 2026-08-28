import CryptoKit
import Darwin
import Foundation

public struct ArchiveRelativePath: Hashable, Codable, Sendable {
    public static let managedRoots: Set<String> = [
        "exports",
        "logs",
        "media",
        "models",
        "thumbnails",
        "vectors",
    ]

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              !rawValue.hasPrefix("/"),
              !rawValue.hasPrefix("~"),
              !rawValue.contains("\\"),
              !rawValue.unicodeScalars.contains(where: { $0.value == 0 }),
              !rawValue.hasSuffix(".partial")
        else {
            throw ArchiveFileStoreError.invalidRelativePath(rawValue)
        }
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard let root = components.first,
              Self.managedRoots.contains(String(root)),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ArchiveFileStoreError.invalidRelativePath(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ArchiveWriteBoundary: String, Codable, Equatable, Sendable {
    case beforeRename
    case afterRenameBeforeCommit
}

public enum ArchiveFileStoreError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case destinationAlreadyExists(String)
    case partialAlreadyExists(String)
    case symbolicLinkForbidden(String)
    case nonRegularPartial(String)
    case injectedFault(ArchiveWriteBoundary)
}

public struct ArchiveFileIntegrity: Equatable, Sendable {
    public let relativePath: ArchiveRelativePath
    public let byteCount: Int64
    public let sha256: Data

    public var sha256Hex: String {
        sha256.map { String(format: "%02x", $0) }.joined()
    }
}

public final class ArchiveFileStore: @unchecked Sendable {
    public let paths: ArchivePaths

    private let fileManager: FileManager

    public init(paths: ArchivePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func url(for relativePath: ArchiveRelativePath) -> URL {
        paths.root.appending(path: relativePath.rawValue, directoryHint: .notDirectory)
    }

    public func partialURL(for relativePath: ArchiveRelativePath) -> URL {
        let finalURL = url(for: relativePath)
        return finalURL.deletingLastPathComponent().appending(
            path: ".\(finalURL.lastPathComponent).partial",
            directoryHint: .notDirectory
        )
    }

    @discardableResult
    public func write(
        _ contents: Data,
        to relativePath: ArchiveRelativePath,
        fault: ArchiveWriteBoundary? = nil,
        databaseCommit: (ArchiveFileIntegrity) throws -> Void = { _ in }
    ) throws -> ArchiveFileIntegrity {
        let finalURL = url(for: relativePath)
        let partialURL = partialURL(for: relativePath)
        try validateDestination(finalURL)
        try ArchivePathProvider.createOwnerOnlyDirectory(
            at: finalURL.deletingLastPathComponent(),
            beneath: paths.root,
            fileManager: fileManager
        )
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw ArchiveFileStoreError.destinationAlreadyExists(relativePath.rawValue)
        }
        guard !fileManager.fileExists(atPath: partialURL.path) else {
            throw ArchiveFileStoreError.partialAlreadyExists(relativePath.rawValue)
        }

        var promoted = false
        do {
            try contents.write(to: partialURL, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: ArchivePathProvider.filePermissions],
                ofItemAtPath: partialURL.path
            )
            try synchronizeFile(at: partialURL)
            let integrity = ArchiveFileIntegrity(
                relativePath: relativePath,
                byteCount: Int64(contents.count),
                sha256: Data(SHA256.hash(data: contents))
            )

            if fault == .beforeRename {
                throw ArchiveFileStoreError.injectedFault(.beforeRename)
            }

            try fileManager.moveItem(at: partialURL, to: finalURL)
            promoted = true
            try fileManager.setAttributes(
                [.posixPermissions: ArchivePathProvider.filePermissions],
                ofItemAtPath: finalURL.path
            )
            try synchronizeDirectory(at: finalURL.deletingLastPathComponent())

            if fault == .afterRenameBeforeCommit {
                throw ArchiveFileStoreError.injectedFault(.afterRenameBeforeCommit)
            }

            try databaseCommit(integrity)
            return integrity
        } catch {
            let preservesCrashArtifact = error as? ArchiveFileStoreError == .injectedFault(.beforeRename)
            if !promoted,
               !preservesCrashArtifact,
               fileManager.fileExists(atPath: partialURL.path)
            {
                try? fileManager.removeItem(at: partialURL)
            }
            throw error
        }
    }

    static func sha256(of fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private func validateDestination(_ finalURL: URL) throws {
        let root = paths.root.standardizedFileURL
        let standardized = finalURL.standardizedFileURL
        guard standardized.path.hasPrefix(root.path + "/") else {
            throw ArchiveFileStoreError.invalidRelativePath(finalURL.path)
        }

        var current = root
        let rootComponents = root.pathComponents
        for component in standardized.pathComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            do {
                let attributes = try fileManager.attributesOfItem(atPath: current.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw ArchiveFileStoreError.symbolicLinkForbidden(current.path)
                }
            } catch {
                let cocoaError = error as NSError
                if cocoaError.domain == NSCocoaErrorDomain,
                   cocoaError.code == NSFileReadNoSuchFileError
                {
                    continue
                }
                throw error
            }
        }
    }

    private func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
