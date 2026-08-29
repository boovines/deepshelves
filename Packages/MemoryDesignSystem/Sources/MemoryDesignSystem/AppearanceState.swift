import Foundation

public enum MemoryAppearanceMode: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public struct MemoryAppearanceState: Codable, Equatable, Sendable {
    public let mode: MemoryAppearanceMode

    public init(mode: MemoryAppearanceMode) {
        self.mode = mode
    }

    public static let freshProfile = MemoryAppearanceState(mode: .light)
}

public enum MemoryAppearanceStateStoreError: Error, Equatable, Sendable {
    case unsafePath
    case invalidState
}

public actor FileMemoryAppearanceStateStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> MemoryAppearanceState {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return .freshProfile }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MemoryAppearanceStateStoreError.unsafePath
        }
        do {
            return try JSONDecoder().decode(
                MemoryAppearanceState.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw MemoryAppearanceStateStoreError.invalidState
        }
    }

    public func save(_ state: MemoryAppearanceState) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MemoryAppearanceStateStoreError.unsafePath
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
