import Foundation

public struct ArchivePaths: Equatable, Sendable {
    public let root: URL
    public let database: URL
    public let media: URL
    public let thumbnails: URL
    public let vectors: URL
    public let models: URL
    public let exports: URL
    public let quarantine: URL
    public let logs: URL

    public var databaseFile: URL {
        database.appendingPathComponent("archive.sqlite3", isDirectory: false)
    }

    public var directories: [URL] {
        [root, database, media, thumbnails, vectors, models, exports, quarantine, logs]
    }
}

public enum ArchivePathError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case rootEscapesApplicationSupport
    case symbolicLinkForbidden(String)
}

public enum ArchivePathProvider: Sendable {
    public static let directoryPermissions = 0o700
    public static let filePermissions = 0o600

    public static func prepare(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ArchivePaths {
        let supportDirectory: URL
        if let applicationSupportDirectory {
            supportDirectory = applicationSupportDirectory
        } else if let discovered = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            supportDirectory = discovered
        } else {
            throw ArchivePathError.applicationSupportUnavailable
        }

        let standardizedSupport = supportDirectory.standardizedFileURL
        let root = standardizedSupport
            .appendingPathComponent("LocalMemory", isDirectory: true)
            .standardizedFileURL
        let supportPrefix = standardizedSupport.path.hasSuffix("/")
            ? standardizedSupport.path
            : standardizedSupport.path + "/"
        guard root.path.hasPrefix(supportPrefix) else {
            throw ArchivePathError.rootEscapesApplicationSupport
        }

        let paths = ArchivePaths(
            root: root,
            database: root.appendingPathComponent("database", isDirectory: true),
            media: root.appendingPathComponent("media", isDirectory: true),
            thumbnails: root.appendingPathComponent("thumbnails", isDirectory: true),
            vectors: root.appendingPathComponent("vectors", isDirectory: true),
            models: root.appendingPathComponent("models", isDirectory: true),
            exports: root.appendingPathComponent("exports", isDirectory: true),
            quarantine: root.appendingPathComponent("quarantine", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        for directory in paths.directories {
            try rejectSymbolicLink(at: directory, fileManager: fileManager)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            try fileManager.setAttributes(
                [.posixPermissions: directoryPermissions],
                ofItemAtPath: directory.path
            )
        }
        try enforceOwnerOnlyTree(at: paths.root, fileManager: fileManager)
        return paths
    }

    static func createOwnerOnlyDirectory(
        at directory: URL,
        beneath root: URL,
        fileManager: FileManager = .default
    ) throws {
        let standardizedRoot = root.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        guard standardizedDirectory.path.hasPrefix(standardizedRoot.path + "/") else {
            throw ArchivePathError.rootEscapesApplicationSupport
        }

        var current = standardizedRoot
        let rootComponents = standardizedRoot.pathComponents
        for component in standardizedDirectory.pathComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            try rejectSymbolicLink(at: current, fileManager: fileManager)
            if !fileManager.fileExists(atPath: current.path) {
                try fileManager.createDirectory(
                    at: current,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: directoryPermissions]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: directoryPermissions],
                ofItemAtPath: current.path
            )
        }
    }

    static func enforceOwnerOnlyTree(
        at root: URL,
        fileManager: FileManager = .default
    ) throws {
        try rejectSymbolicLink(at: root, fileManager: fileManager)
        try fileManager.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: root.path
        )
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw ArchivePathError.symbolicLinkForbidden(url.path)
            }
            if values.isDirectory == true {
                try fileManager.setAttributes(
                    [.posixPermissions: directoryPermissions],
                    ofItemAtPath: url.path
                )
            } else if values.isRegularFile == true {
                try fileManager.setAttributes(
                    [.posixPermissions: filePermissions],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    static func rejectSymbolicLink(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ArchivePathError.symbolicLinkForbidden(url.path)
            }
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileReadNoSuchFileError
            {
                return
            }
            throw error
        }
    }
}
