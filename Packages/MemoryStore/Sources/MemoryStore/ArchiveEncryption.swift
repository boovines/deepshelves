import Foundation
import Security

public protocol ArchiveKeyStoring: Sendable {
    func fetch(account: String) throws -> Data?
    func generateAndStore(account: String) throws -> Data
    func store(_ key: Data, account: String) throws
    func delete(account: String) throws
}

public struct SystemArchiveKeyStore: ArchiveKeyStoring {
    public init() {}

    public func fetch(account: String) throws -> Data? {
        do {
            return try SharedKeychainKeyStore.fetch(account: account)
        } catch SharedKeychainError.keychain(errSecItemNotFound) {
            return nil
        }
    }

    public func generateAndStore(account: String) throws -> Data {
        try SharedKeychainKeyStore.generateAndStore(account: account)
    }

    public func store(_ key: Data, account: String) throws {
        try SharedKeychainKeyStore.store(key, account: account)
    }

    public func delete(account: String) throws {
        try SharedKeychainKeyStore.delete(account: account, ignoreMissing: true)
    }
}

public enum ArchiveKeyResolutionOrigin: String, Codable, Equatable, Sendable {
    case existing
    case generated
}

public struct ArchiveKeyResolution: Equatable, Sendable {
    public let key: Data
    public let origin: ArchiveKeyResolutionOrigin

    public init(key: Data, origin: ArchiveKeyResolutionOrigin) {
        self.key = key
        self.origin = origin
    }
}

public enum ArchiveKeyManagerError: Error, Equatable, Sendable {
    case keyMissingForExistingArchive
    case invalidKeyLength
}

public struct ArchiveKeyManager: Sendable {
    private let store: any ArchiveKeyStoring

    public init(store: any ArchiveKeyStoring = SystemArchiveKeyStore()) {
        self.store = store
    }

    public func resolve(paths: ArchivePaths) throws -> ArchiveKeyResolution {
        if let existing = try store.fetch(account: SharedKeychainKeyStore.archiveAccount) {
            guard existing.count == LM008StoreDefaults.keyByteCount else {
                throw ArchiveKeyManagerError.invalidKeyLength
            }
            return ArchiveKeyResolution(key: existing, origin: .existing)
        }
        guard !hasExistingArchiveData(paths: paths) else {
            throw ArchiveKeyManagerError.keyMissingForExistingArchive
        }
        let generated = try store.generateAndStore(account: SharedKeychainKeyStore.archiveAccount)
        guard generated.count == LM008StoreDefaults.keyByteCount else {
            try? store.delete(account: SharedKeychainKeyStore.archiveAccount)
            throw ArchiveKeyManagerError.invalidKeyLength
        }
        return ArchiveKeyResolution(key: generated, origin: .generated)
    }

    private func hasExistingArchiveData(paths: ArchivePaths) -> Bool {
        let fileManager = FileManager.default
        if [
            paths.databaseFile.path,
            paths.databaseFile.path + "-wal",
            paths.databaseFile.path + "-shm",
        ].contains(where: { fileManager.fileExists(atPath: $0) }) {
            return true
        }
        guard
            let enumerator = fileManager.enumerator(
                at: paths.root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
    }
}

public enum ArchiveResetError: Error, Equatable, Sendable {
    case confirmationMismatch
    case invalidArchiveLocation
}

public struct ArchiveResetReceipt: Equatable, Sendable {
    public let deletedRoot: URL
    public let keyDeleted: Bool

    public init(deletedRoot: URL, keyDeleted: Bool) {
        self.deletedRoot = deletedRoot
        self.keyDeleted = keyDeleted
    }
}

public struct ArchiveResetCoordinator: Sendable {
    public static let requiredConfirmation = "DELETE LOCAL MEMORY ARCHIVE"

    private let store: any ArchiveKeyStoring

    public init(store: any ArchiveKeyStoring = SystemArchiveKeyStore()) {
        self.store = store
    }

    public func reset(
        paths: ArchivePaths,
        typedConfirmation: String
    ) throws -> ArchiveResetReceipt {
        guard typedConfirmation == Self.requiredConfirmation else {
            throw ArchiveResetError.confirmationMismatch
        }
        let root = paths.root.standardizedFileURL
        let support = root.deletingLastPathComponent().standardizedFileURL
        guard root.lastPathComponent == "LocalMemory",
            root.path.hasPrefix(support.path + "/")
        else {
            throw ArchiveResetError.invalidArchiveLocation
        }

        let staged = support.appending(
            path: ".LocalMemory.reset-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let fileManager = FileManager.default
        let hadArchive = fileManager.fileExists(atPath: root.path)
        let priorKey = try store.fetch(account: SharedKeychainKeyStore.archiveAccount)
        if hadArchive {
            try ArchivePathProvider.rejectSymbolicLink(at: root, fileManager: fileManager)
            try fileManager.moveItem(at: root, to: staged)
        }
        do {
            try store.delete(account: SharedKeychainKeyStore.archiveAccount)
        } catch {
            if hadArchive,
                fileManager.fileExists(atPath: staged.path),
                !fileManager.fileExists(atPath: root.path)
            {
                try? fileManager.moveItem(at: staged, to: root)
            }
            throw error
        }
        if hadArchive {
            do {
                try fileManager.removeItem(at: staged)
            } catch {
                if let priorKey {
                    try? store.store(priorKey, account: SharedKeychainKeyStore.archiveAccount)
                }
                if fileManager.fileExists(atPath: staged.path),
                    !fileManager.fileExists(atPath: root.path)
                {
                    try? fileManager.moveItem(at: staged, to: root)
                }
                throw error
            }
        }
        return ArchiveResetReceipt(deletedRoot: root, keyDeleted: true)
    }
}
