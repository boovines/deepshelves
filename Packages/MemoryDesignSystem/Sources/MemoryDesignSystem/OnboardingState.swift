import Foundation

public enum OnboardingDefaults: Sendable {
    public static let windowWidth = 760
    public static let windowHeight = 620
    public static let retentionDays = 30
    public static let storageCapGigabytes = 20
    public static let foregroundOnlyStatement = "Local Memory records only your active window. Background windows, notifications, the Dock, and the desktop are not stored."
    public static let visiblePermissionKinds: [OnboardingPermissionKind] = [
        .screenRecording,
        .accessibility,
    ]
}

public enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case permissions
    case privacy
    case ready

    public var number: Int {
        switch self {
        case .welcome: 1
        case .permissions: 2
        case .privacy: 3
        case .ready: 4
        }
    }

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .privacy: "Privacy"
        case .ready: "Ready"
        }
    }

    public var systemImage: String {
        switch self {
        case .welcome: "hand.wave"
        case .permissions: "lock.shield"
        case .privacy: "hand.raised"
        case .ready: "checkmark.circle"
        }
    }
}

public enum OnboardingPermissionKind: String, CaseIterable, Codable, Sendable {
    case screenRecording
    case accessibility
    case microphone

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }

    public var requirement: String {
        switch self {
        case .screenRecording: "Required"
        case .accessibility: "Recommended"
        case .microphone: "Optional"
        }
    }
}

public enum OnboardingPermissionStatus: String, CaseIterable, Codable, Sendable {
    case notDetermined
    case granted
    case denied
    case revoked

    public var presentation: PermissionPresentation {
        switch self {
        case .notDetermined: PermissionState.unknown.presentation
        case .granted: PermissionState.granted.presentation
        case .denied: PermissionState.denied.presentation
        case .revoked: PermissionState.revoked.presentation
        }
    }
}

public struct OnboardingSnapshot: Codable, Equatable, Sendable {
    public let step: OnboardingStep
    public let screenRecording: OnboardingPermissionStatus
    public let accessibility: OnboardingPermissionStatus
    public let explicitPermissionActions: [OnboardingPermissionKind: Int]
    public let launchCount: Int
    public let isComplete: Bool

    public init(
        step: OnboardingStep,
        screenRecording: OnboardingPermissionStatus,
        accessibility: OnboardingPermissionStatus,
        explicitPermissionActions: [OnboardingPermissionKind: Int],
        launchCount: Int,
        isComplete: Bool
    ) {
        self.step = step
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.explicitPermissionActions = explicitPermissionActions
        self.launchCount = launchCount
        self.isComplete = isComplete
    }

    public static let `default` = OnboardingSnapshot(
        step: .welcome,
        screenRecording: .notDetermined,
        accessibility: .notDetermined,
        explicitPermissionActions: [:],
        launchCount: 0,
        isComplete: false
    )

    public var canRecord: Bool {
        screenRecording == .granted
    }

    public func permissionStatus(_ kind: OnboardingPermissionKind) -> OnboardingPermissionStatus {
        switch kind {
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        case .microphone: .notDetermined
        }
    }
}

public protocol OnboardingStateStoring: Sendable {
    func load() async throws -> OnboardingSnapshot?
    func save(_ snapshot: OnboardingSnapshot) async throws
}

public enum OnboardingStateStoreError: Error, Equatable, Sendable {
    case invalidState
}

public actor FileOnboardingStateStore: OnboardingStateStoring {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> OnboardingSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(
                OnboardingSnapshot.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw OnboardingStateStoreError.invalidState
        }
    }

    public func save(_ snapshot: OnboardingSnapshot) throws {
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
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

public actor InMemoryOnboardingStateStore: OnboardingStateStoring {
    private var snapshot: OnboardingSnapshot?

    public init(snapshot: OnboardingSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func load() -> OnboardingSnapshot? {
        snapshot
    }

    public func save(_ snapshot: OnboardingSnapshot) {
        self.snapshot = snapshot
    }
}

public actor OnboardingCoordinator {
    private let store: any OnboardingStateStoring
    private var snapshot: OnboardingSnapshot = .default
    private var isLaunched = false

    public init(store: any OnboardingStateStoring) {
        self.store = store
    }

    public func launch(
        overrides: [OnboardingPermissionKind: OnboardingPermissionStatus]
    ) async throws -> OnboardingSnapshot {
        let loaded: OnboardingSnapshot
        do {
            loaded = try await store.load() ?? .default
        } catch {
            loaded = .default
        }
        snapshot = replacing(
            loaded,
            screenRecording: overrides[.screenRecording] ?? loaded.screenRecording,
            accessibility: overrides[.accessibility] ?? loaded.accessibility,
            launchCount: loaded.launchCount + 1
        )
        isLaunched = true
        try await store.save(snapshot)
        return snapshot
    }

    public func advance() async throws -> OnboardingSnapshot {
        try requireLaunch()
        let index = OnboardingStep.allCases.firstIndex(of: snapshot.step) ?? 0
        let next = OnboardingStep.allCases[min(index + 1, OnboardingStep.allCases.count - 1)]
        snapshot = replacing(snapshot, step: next)
        try await store.save(snapshot)
        return snapshot
    }

    public func retreat() async throws -> OnboardingSnapshot {
        try requireLaunch()
        let index = OnboardingStep.allCases.firstIndex(of: snapshot.step) ?? 0
        let prior = OnboardingStep.allCases[max(index - 1, 0)]
        snapshot = replacing(snapshot, step: prior)
        try await store.save(snapshot)
        return snapshot
    }

    public func select(step: OnboardingStep) async throws -> OnboardingSnapshot {
        try requireLaunch()
        snapshot = replacing(snapshot, step: step)
        try await store.save(snapshot)
        return snapshot
    }

    public func updatePermission(
        _ kind: OnboardingPermissionKind,
        status: OnboardingPermissionStatus
    ) async throws -> OnboardingSnapshot {
        try requireLaunch()
        switch kind {
        case .screenRecording:
            snapshot = replacing(snapshot, screenRecording: status)
        case .accessibility:
            snapshot = replacing(snapshot, accessibility: status)
        case .microphone:
            return snapshot
        }
        try await store.save(snapshot)
        return snapshot
    }

    public func registerExplicitPermissionAction(
        _ kind: OnboardingPermissionKind
    ) async throws -> OnboardingSnapshot {
        try requireLaunch()
        guard OnboardingDefaults.visiblePermissionKinds.contains(kind) else { return snapshot }
        var actions = snapshot.explicitPermissionActions
        actions[kind, default: 0] += 1
        snapshot = replacing(snapshot, explicitPermissionActions: actions)
        try await store.save(snapshot)
        return snapshot
    }

    public func complete() async throws -> OnboardingSnapshot {
        try requireLaunch()
        snapshot = replacing(snapshot, step: .ready, isComplete: true)
        try await store.save(snapshot)
        return snapshot
    }

    private func requireLaunch() throws {
        guard isLaunched else { throw OnboardingStateStoreError.invalidState }
    }

    private func replacing(
        _ source: OnboardingSnapshot,
        step: OnboardingStep? = nil,
        screenRecording: OnboardingPermissionStatus? = nil,
        accessibility: OnboardingPermissionStatus? = nil,
        explicitPermissionActions: [OnboardingPermissionKind: Int]? = nil,
        launchCount: Int? = nil,
        isComplete: Bool? = nil
    ) -> OnboardingSnapshot {
        OnboardingSnapshot(
            step: step ?? source.step,
            screenRecording: screenRecording ?? source.screenRecording,
            accessibility: accessibility ?? source.accessibility,
            explicitPermissionActions: explicitPermissionActions ?? source.explicitPermissionActions,
            launchCount: launchCount ?? source.launchCount,
            isComplete: isComplete ?? source.isComplete
        )
    }
}

public enum OnboardingAccessibilityTranscript {
    public static let canonicalData = Data(
        """
        Window, Welcome to Local Memory
        Sidebar, four onboarding steps
        Step 1 of 4, Welcome
        Heading, Your screen memory stays on this Mac
        Text, Nothing is uploaded; normal use has no network access
        Button, Continue
        Step 2 of 4, Permissions
        Screen Recording, Required, Open System Settings
        Accessibility, Recommended, Open System Settings
        Step 3 of 4, Privacy
        \(OnboardingDefaults.foregroundOnlyStatement)
        Background fixture window, not stored
        Active foreground fixture, stored
        Saved image contains active window only
        Step 4 of 4, Ready
        Text, 30-day retention and 20-GB storage cap
        Text, Archive is stored locally in Application Support
        Button, Finish
        """.appending("\n").utf8
    )
}
