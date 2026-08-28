import Foundation

public enum AppLifecycleDefaults: Sendable {
    public static let opensMainWindowAtLaunch = false
}

public enum LocalMemoryRuntimeStatus: String, CaseIterable, Codable, Sendable {
    case recording
    case paused
    case permissionRequired
    case diskFull
    case indexing

    public var menuProjection: RuntimeMenuProjection {
        switch self {
        case .recording:
            RuntimeMenuProjection(
                statusLabel: "Recording",
                statusSymbol: "record.circle",
                primaryActionLabel: "Pause Recording"
            )
        case .paused:
            RuntimeMenuProjection(
                statusLabel: "Paused",
                statusSymbol: "pause.circle",
                primaryActionLabel: "Resume Recording"
            )
        case .permissionRequired:
            RuntimeMenuProjection(
                statusLabel: "Recording unavailable",
                statusSymbol: "exclamationmark.triangle",
                primaryActionLabel: "Review Permissions…"
            )
        case .diskFull:
            RuntimeMenuProjection(
                statusLabel: "Recording unavailable",
                statusSymbol: "externaldrive.badge.exclamationmark",
                primaryActionLabel: "Manage Storage…"
            )
        case .indexing:
            RuntimeMenuProjection(
                statusLabel: "Indexing",
                statusSymbol: "arrow.triangle.2.circlepath",
                primaryActionLabel: "Pause Recording"
            )
        }
    }
}

public struct RuntimeMenuProjection: Equatable, Sendable {
    public let statusLabel: String
    public let statusSymbol: String
    public let primaryActionLabel: String

    public init(
        statusLabel: String,
        statusSymbol: String,
        primaryActionLabel: String
    ) {
        self.statusLabel = statusLabel
        self.statusSymbol = statusSymbol
        self.primaryActionLabel = primaryActionLabel
    }
}

public enum AppLifecycleRecoveryReason: String, Codable, Sendable {
    case invalidPersistedState
}

public struct AppLifecycleSnapshot: Equatable, Sendable {
    public let status: LocalMemoryRuntimeStatus
    public let launchCount: Int
    public let mainWindowVisible: Bool
    public let recoveryReason: AppLifecycleRecoveryReason?

    public init(
        status: LocalMemoryRuntimeStatus,
        launchCount: Int,
        mainWindowVisible: Bool,
        recoveryReason: AppLifecycleRecoveryReason?
    ) {
        self.status = status
        self.launchCount = launchCount
        self.mainWindowVisible = mainWindowVisible
        self.recoveryReason = recoveryReason
    }
}

public enum AppLifecycleStoreError: Error, Equatable, Sendable {
    case invalidPersistedState
}

public struct FileAppLifecycleStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    fileprivate func load() throws -> PersistedAppLifecycleState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                PersistedAppLifecycleState.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw AppLifecycleStoreError.invalidPersistedState
        }
    }

    fileprivate func save(_ state: PersistedAppLifecycleState) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

private struct PersistedAppLifecycleState: Codable, Sendable {
    let status: LocalMemoryRuntimeStatus
    let launchCount: Int
}

public actor LocalMemoryAppLifecycle {
    private let store: FileAppLifecycleStateStore
    private var snapshot: AppLifecycleSnapshot?

    public init(store: FileAppLifecycleStateStore) {
        self.store = store
    }

    public func launch(initialStatus: LocalMemoryRuntimeStatus) throws -> AppLifecycleSnapshot {
        let persisted: PersistedAppLifecycleState?
        let recoveryReason: AppLifecycleRecoveryReason?
        do {
            persisted = try store.load()
            recoveryReason = nil
        } catch AppLifecycleStoreError.invalidPersistedState {
            persisted = nil
            recoveryReason = .invalidPersistedState
        }

        let launched = AppLifecycleSnapshot(
            status: recoveryReason == nil ? (persisted?.status ?? initialStatus) : .permissionRequired,
            launchCount: (persisted?.launchCount ?? 0) + 1,
            mainWindowVisible: AppLifecycleDefaults.opensMainWindowAtLaunch,
            recoveryReason: recoveryReason
        )
        try persist(launched)
        snapshot = launched
        return launched
    }

    public func currentSnapshot() -> AppLifecycleSnapshot? {
        snapshot
    }

    public func transition(to status: LocalMemoryRuntimeStatus) throws -> AppLifecycleSnapshot {
        let current = try requireSnapshot()
        let updated = AppLifecycleSnapshot(
            status: status,
            launchCount: current.launchCount,
            mainWindowVisible: current.mainWindowVisible,
            recoveryReason: current.recoveryReason
        )
        try persist(updated)
        snapshot = updated
        return updated
    }

    public func setMainWindowVisible(_ visible: Bool) throws -> AppLifecycleSnapshot {
        let current = try requireSnapshot()
        let updated = AppLifecycleSnapshot(
            status: current.status,
            launchCount: current.launchCount,
            mainWindowVisible: visible,
            recoveryReason: current.recoveryReason
        )
        snapshot = updated
        return updated
    }

    public func performPrimaryAction() throws -> AppLifecycleSnapshot {
        let current = try requireSnapshot()
        let nextStatus: LocalMemoryRuntimeStatus
        switch current.status {
        case .recording, .indexing:
            nextStatus = .paused
        case .paused:
            nextStatus = .recording
        case .permissionRequired, .diskFull:
            nextStatus = current.status
        }
        return try transition(to: nextStatus)
    }

    private func requireSnapshot() throws -> AppLifecycleSnapshot {
        guard let snapshot else {
            throw CocoaError(.coderReadCorrupt)
        }
        return snapshot
    }

    private func persist(_ snapshot: AppLifecycleSnapshot) throws {
        try store.save(
            PersistedAppLifecycleState(
                status: snapshot.status,
                launchCount: snapshot.launchCount
            )
        )
    }
}
