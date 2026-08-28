import Foundation

public enum AppLifecycleDefaults: Sendable {
    public static let opensMainWindowAtLaunch = false
}

public enum LocalMemoryRuntimeStatus: String, CaseIterable, Codable, Sendable {
    case recording
    case paused
    case idle
    case sleeping
    case targetUnavailable
    case permissionRequired
    case diskFull
    case stopped
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
        case .idle:
            RuntimeMenuProjection(
                statusLabel: "Idle",
                statusSymbol: "moon.zzz",
                primaryActionLabel: "Pause Recording"
            )
        case .sleeping:
            RuntimeMenuProjection(
                statusLabel: "Recording asleep",
                statusSymbol: "powersleep",
                primaryActionLabel: "Pause Recording"
            )
        case .targetUnavailable:
            RuntimeMenuProjection(
                statusLabel: "Waiting for a foreground window",
                statusSymbol: "rectangle.slash",
                primaryActionLabel: "Pause Recording"
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
        case .stopped:
            RuntimeMenuProjection(
                statusLabel: "Recording stopped",
                statusSymbol: "stop.circle",
                primaryActionLabel: "Review Status…"
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
    public let detailLabel: String?

    public init(
        statusLabel: String,
        statusSymbol: String,
        primaryActionLabel: String,
        detailLabel: String? = nil
    ) {
        self.statusLabel = statusLabel
        self.statusSymbol = statusSymbol
        self.primaryActionLabel = primaryActionLabel
        self.detailLabel = detailLabel
    }
}

public enum AppLifecycleRecoveryReason: String, Codable, Sendable {
    case invalidPersistedState
    case interruptedCapture
}

public struct AppLifecycleSnapshot: Equatable, Sendable {
    public let status: LocalMemoryRuntimeStatus
    public let launchCount: Int
    public let mainWindowVisible: Bool
    public let recoveryReason: AppLifecycleRecoveryReason?
    public let interruptedAt: Date?

    public init(
        status: LocalMemoryRuntimeStatus,
        launchCount: Int,
        mainWindowVisible: Bool,
        recoveryReason: AppLifecycleRecoveryReason?,
        interruptedAt: Date? = nil
    ) {
        self.status = status
        self.launchCount = launchCount
        self.mainWindowVisible = mainWindowVisible
        self.recoveryReason = recoveryReason
        self.interruptedAt = interruptedAt
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
    let updatedAt: Date?
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

        let persistedStatus = persisted?.status
        let interruptedCapture = persistedStatus == .recording || persistedStatus == .indexing
        let effectiveRecoveryReason = interruptedCapture ? .interruptedCapture : recoveryReason
        let launched = AppLifecycleSnapshot(
            status: effectiveRecoveryReason == .invalidPersistedState
                ? .permissionRequired
                : interruptedCapture ? .stopped : (persistedStatus ?? initialStatus),
            launchCount: (persisted?.launchCount ?? 0) + 1,
            mainWindowVisible: AppLifecycleDefaults.opensMainWindowAtLaunch,
            recoveryReason: effectiveRecoveryReason,
            interruptedAt: interruptedCapture ? persisted?.updatedAt : nil
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
            recoveryReason: current.recoveryReason,
            interruptedAt: status == .stopped ? current.interruptedAt : nil
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
            recoveryReason: current.recoveryReason,
            interruptedAt: current.interruptedAt
        )
        snapshot = updated
        return updated
    }

    public func performPrimaryAction() throws -> AppLifecycleSnapshot {
        let current = try requireSnapshot()
        let nextStatus: LocalMemoryRuntimeStatus
        switch current.status {
        case .recording, .indexing, .idle, .sleeping, .targetUnavailable:
            nextStatus = .paused
        case .paused:
            nextStatus = .recording
        case .permissionRequired, .diskFull, .stopped:
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
                launchCount: snapshot.launchCount,
                updatedAt: Date()
            )
        )
    }
}
