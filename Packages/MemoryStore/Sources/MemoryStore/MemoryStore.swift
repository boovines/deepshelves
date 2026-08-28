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
        return paths
    }
}
