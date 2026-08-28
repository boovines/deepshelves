import AppKit
import ApplicationServices
import Foundation

public struct ForegroundApplicationIdentity: Codable, Equatable, Sendable {
    public let processID: Int32
    public let bundleIdentifier: String
    public let localizedName: String

    public init(processID: Int32, bundleIdentifier: String, localizedName: String) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

public enum ForegroundWindowSnapshot: Equatable, Sendable {
    case available(application: ForegroundApplicationIdentity, window: FocusedWindowDescriptor)
    case gap(CaptureGapReason)

    public var focusedWindow: FocusedWindowDescriptor? {
        guard case let .available(_, window) = self else {
            return nil
        }
        return window
    }
}

public protocol ForegroundWindowSnapshotReading: Sendable {
    func readSnapshot() async -> ForegroundWindowSnapshot
}

public struct SystemForegroundWindowSnapshotReader: ForegroundWindowSnapshotReading, Sendable {
    public init() {}

    public func readSnapshot() async -> ForegroundWindowSnapshot {
        guard AXIsProcessTrusted() else {
            return .gap(.noWindow)
        }
        guard let application = await MainActor.run(body: frontmostApplicationIdentity) else {
            return .gap(.noWindow)
        }
        return await Task.detached(priority: .userInitiated) {
            readFocusedWindow(application: application)
        }.value
    }
}

public enum ForegroundApplicationTransitionKind: String, Codable, Equatable, Sendable {
    case initial
    case applicationActivated
    case applicationHidden
    case applicationUnhidden
    case applicationTerminated
    case workspaceWoke
    case screensWoke
}

public struct ForegroundApplicationTransition: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let kind: ForegroundApplicationTransitionKind

    public init(sequence: UInt64, kind: ForegroundApplicationTransitionKind) {
        self.sequence = sequence
        self.kind = kind
    }
}

public struct NSWorkspaceForegroundApplicationMonitor: Sendable {
    public init() {}

    public func transitions() -> AsyncStream<ForegroundApplicationTransition> {
        AsyncStream { continuation in
            let box = WorkspaceTransitionStreamBox(continuation: continuation)
            box.start()
            continuation.onTermination = { _ in
                box.stop()
            }
        }
    }
}

public struct ForegroundCaptureResolution: @unchecked Sendable, Equatable {
    public let snapshot: ForegroundWindowSnapshot
    public let refreshStatus: ShareableWindowRefreshStatus?
    public let resolution: WindowResolution
    public let target: ForegroundWindowCaptureTarget?
    public let pixelPayloadCount: Int

    public init(
        snapshot: ForegroundWindowSnapshot,
        refreshStatus: ShareableWindowRefreshStatus?,
        resolution: WindowResolution,
        target: ForegroundWindowCaptureTarget?
    ) {
        self.snapshot = snapshot
        self.refreshStatus = refreshStatus
        self.resolution = resolution
        self.target = target
        pixelPayloadCount = 0
    }
}

public actor ForegroundCaptureTargetResolver {
    private let snapshotReader: any ForegroundWindowSnapshotReading
    private let refresher: any ShareableWindowRefreshing
    private var cached: (sequence: UInt64, result: ForegroundCaptureResolution)?

    public init(
        snapshotReader: any ForegroundWindowSnapshotReading = SystemForegroundWindowSnapshotReader(),
        refresher: any ShareableWindowRefreshing = ScreenCaptureKitShareableWindowRefresher()
    ) {
        self.snapshotReader = snapshotReader
        self.refresher = refresher
    }

    public func resolve(transitionSequence: UInt64) async -> ForegroundCaptureResolution {
        if let cached, cached.sequence == transitionSequence {
            return cached.result
        }

        let snapshot = await snapshotReader.readSnapshot()
        guard case let .available(_, focused) = snapshot else {
            let reason: CaptureGapReason
            if case let .gap(snapshotReason) = snapshot {
                reason = snapshotReason
            } else {
                reason = .noWindow
            }
            return cache(
                ForegroundCaptureResolution(
                    snapshot: snapshot,
                    refreshStatus: nil,
                    resolution: .gap(reason),
                    target: nil
                ),
                sequence: transitionSequence
            )
        }

        let refresh = await refresher.refresh()
        guard refresh.status == .available else {
            return cache(
                ForegroundCaptureResolution(
                    snapshot: snapshot,
                    refreshStatus: refresh.status,
                    resolution: .gap(.unresolvedWindow),
                    target: nil
                ),
                sequence: transitionSequence
            )
        }
        let resolution = WindowResolver.resolve(
            focused: focused,
            candidates: refresh.targets.map(\ .descriptor)
        )
        let target: ForegroundWindowCaptureTarget?
        if case let .approved(descriptor) = resolution {
            target = refresh.targets.first(where: {
                $0.windowID == descriptor.windowID && $0.isEligibleForegroundWindow
            })
        } else {
            target = nil
        }
        let failClosedResolution: WindowResolution = target == nil && resolution.isApproved
            ? .gap(.unresolvedWindow)
            : resolution
        return cache(
            ForegroundCaptureResolution(
                snapshot: snapshot,
                refreshStatus: refresh.status,
                resolution: failClosedResolution,
                target: target
            ),
            sequence: transitionSequence
        )
    }

    public func noteTargetDisappeared(windowID: UInt32) {
        guard cached?.result.target?.windowID == windowID else {
            return
        }
        cached = nil
    }

    private func cache(
        _ result: ForegroundCaptureResolution,
        sequence: UInt64
    ) -> ForegroundCaptureResolution {
        cached = (sequence, result)
        return result
    }
}

private extension WindowResolution {
    var isApproved: Bool {
        if case .approved = self {
            return true
        }
        return false
    }
}

@MainActor
private func frontmostApplicationIdentity() -> ForegroundApplicationIdentity? {
    guard let application = NSWorkspace.shared.frontmostApplication else {
        return nil
    }
    return ForegroundApplicationIdentity(
        processID: application.processIdentifier,
        bundleIdentifier: application.bundleIdentifier ?? "",
        localizedName: application.localizedName ?? ""
    )
}

private func readFocusedWindow(
    application: ForegroundApplicationIdentity
) -> ForegroundWindowSnapshot {
    let applicationElement = AXUIElementCreateApplication(application.processID)
    AXUIElementSetMessagingTimeout(applicationElement, 0.05)

    let focusedWindow: AXUIElement? = axAttribute(
        applicationElement,
        kAXFocusedWindowAttribute
    )
    let focusedElement: AXUIElement? = axAttribute(
        applicationElement,
        kAXFocusedUIElementAttribute
    )
    let topLevelWindow: AXUIElement? = focusedElement.flatMap {
        axAttribute($0, kAXTopLevelUIElementAttribute)
    }
    guard let window = focusedWindow ?? topLevelWindow else {
        return .gap(.noWindow)
    }

    var windowProcessID: pid_t = 0
    guard AXUIElementGetPid(window, &windowProcessID) == .success,
          windowProcessID == application.processID,
          let bounds = axBounds(window)
    else {
        return .gap(.unresolvedWindow)
    }
    let topLevelBounds: PointRect
    if let topLevelWindow {
        var topLevelProcessID: pid_t = 0
        guard AXUIElementGetPid(topLevelWindow, &topLevelProcessID) == .success,
              topLevelProcessID == application.processID,
              let confirmedBounds = axBounds(topLevelWindow)
        else {
            return .gap(.unresolvedWindow)
        }
        topLevelBounds = confirmedBounds
    } else {
        topLevelBounds = bounds
    }
    let identitySource: AXWindowIdentitySource
    switch (focusedWindow, topLevelWindow) {
    case (_?, _?): identitySource = .focusedAndTopLevel
    case (_?, nil): identitySource = .focusedWindow
    case (nil, _?): identitySource = .topLevelWindow
    case (nil, nil): return .gap(.noWindow)
    }
    let role: String = axAttribute(window, kAXRoleAttribute) ?? ""
    let subrole: String? = axAttribute(window, kAXSubroleAttribute)
    let title: String? = axAttribute(window, kAXTitleAttribute)
    let minimized: Bool = axAttribute(window, kAXMinimizedAttribute) ?? false
    return .available(
        application: application,
        window: FocusedWindowDescriptor(
            processID: windowProcessID,
            bounds: bounds,
            title: title,
            isMinimized: minimized,
            role: role,
            subrole: subrole,
            topLevelBounds: topLevelBounds,
            hasConfirmedAXIdentity: true,
            identitySource: identitySource
        )
    )
}

private func axBounds(_ element: AXUIElement) -> PointRect? {
    guard let positionValue: AXValue = axAttribute(element, kAXPositionAttribute),
          let sizeValue: AXValue = axAttribute(element, kAXSizeAttribute)
    else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &position),
          AXValueGetValue(sizeValue, .cgSize, &size),
          size.width > 0,
          size.height > 0
    else {
        return nil
    }
    return PointRect(
        x: position.x,
        y: position.y,
        width: size.width,
        height: size.height
    )
}

private func axAttribute<Value>(_ element: AXUIElement, _ attribute: String) -> Value? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? Value
}

private final class WorkspaceTransitionStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<ForegroundApplicationTransition>.Continuation
    private var sequence: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init(continuation: AsyncStream<ForegroundApplicationTransition>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        continuation.yield(ForegroundApplicationTransition(sequence: 0, kind: .initial))
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, ForegroundApplicationTransitionKind)] = [
            (NSWorkspace.didActivateApplicationNotification, .applicationActivated),
            (NSWorkspace.didHideApplicationNotification, .applicationHidden),
            (NSWorkspace.didUnhideApplicationNotification, .applicationUnhidden),
            (NSWorkspace.didTerminateApplicationNotification, .applicationTerminated),
            (NSWorkspace.didWakeNotification, .workspaceWoke),
            (NSWorkspace.screensDidWakeNotification, .screensWoke),
        ]
        observers = names.map { name, kind in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.yield(kind)
            }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        let tokens = lock.withLock { () -> [NSObjectProtocol] in
            defer { observers.removeAll() }
            return observers
        }
        tokens.forEach(center.removeObserver)
        continuation.finish()
    }

    private func yield(_ kind: ForegroundApplicationTransitionKind) {
        let next = lock.withLock { () -> UInt64 in
            sequence &+= 1
            return sequence
        }
        continuation.yield(ForegroundApplicationTransition(sequence: next, kind: kind))
    }
}
