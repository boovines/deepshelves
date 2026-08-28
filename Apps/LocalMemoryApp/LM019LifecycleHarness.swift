import AppKit
import Foundation
import MemoryCapture

struct LM019LifecycleReport: Codable, Equatable {
    let schemaVersion: Int
    let permission: ScreenRecordingPermission
    let initialState: String
    let initialFramesDelivered: Int
    let initialRefreshStatus: ShareableWindowRefreshStatus
    let targetWindowID: UInt32
    let firstRunningState: String
    let framesBeforeDisplayRestart: Int
    let framesAfterDisplayRestart: Int
    let finalState: String
    let deliveredSurfaceKinds: [CaptureSurfaceKind]
    let compositedDisplayFramesDelivered: Int
    let framesPersisted: Int
    let pixelBufferLeasesReleased: Int
    let allInvariantsPassed: Bool
}

enum LM019LifecycleHarnessError: Error {
    case permissionDenied
    case targetUnavailable(ShareableWindowRefreshStatus)
    case streamDidNotDeliver
    case streamDidNotRestart
}

@MainActor
enum LM019LifecycleHarness {
    static func run(outputURL: URL) async throws {
        NSApplication.shared.activate()
        NSApplication.shared.keyWindow?.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1))

        let permissionProbe = ScreenCaptureKitPermissionProbe()
        let permission = await permissionProbe.currentPermission()
        guard permission == .granted else {
            throw LM019LifecycleHarnessError.permissionDenied
        }
        let refresher = ScreenCaptureKitShareableWindowRefresher()
        let driver = ScreenCaptureKitForegroundWindowStreamDriver()
        let counter = LM019FrameCounter()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permissionProbe,
            refresher: refresher,
            streamDriver: driver,
            frameHandler: { frame in
                counter.accept(frame)
            }
        )

        let initialState = await lifecycle.state
        await lifecycle.reconcile(targetWindowID: nil)
        let initialFrames = counter.snapshot().count
        let refresh = await refresher.refresh()
        let processID = ProcessInfo.processInfo.processIdentifier
        guard refresh.status == .available,
              let target = refresh.targets.first(where: {
                  $0.processID == processID && $0.isEligibleForegroundWindow
              })
        else {
            throw LM019LifecycleHarnessError.targetUnavailable(refresh.status)
        }

        await lifecycle.reconcile(targetWindowID: target.windowID)
        let firstRunningState = await lifecycle.state
        guard await waitForFrames(counter, greaterThan: 0) else {
            await lifecycle.stop()
            throw LM019LifecycleHarnessError.streamDidNotDeliver
        }
        let framesBeforeRestart = counter.snapshot().count

        await lifecycle.restartAfterDisplayChange(targetWindowID: target.windowID)
        guard await waitForFrames(counter, greaterThan: framesBeforeRestart) else {
            await lifecycle.stop()
            throw LM019LifecycleHarnessError.streamDidNotRestart
        }
        let afterRestart = counter.snapshot()
        await lifecycle.stop()
        let finalState = await lifecycle.state

        let report = LM019LifecycleReport(
            schemaVersion: 1,
            permission: permission,
            initialState: initialState.evidenceName,
            initialFramesDelivered: initialFrames,
            initialRefreshStatus: refresh.status,
            targetWindowID: target.windowID,
            firstRunningState: firstRunningState.evidenceName,
            framesBeforeDisplayRestart: framesBeforeRestart,
            framesAfterDisplayRestart: afterRestart.count,
            finalState: finalState.evidenceName,
            deliveredSurfaceKinds: afterRestart.surfaceKinds.sorted { $0.rawValue < $1.rawValue },
            compositedDisplayFramesDelivered: 0,
            framesPersisted: 0,
            pixelBufferLeasesReleased: afterRestart.releasedCount,
            allInvariantsPassed: initialState == .stoppedNoEligibleTarget
                && initialFrames == 0
                && firstRunningState == .running(
                    windowID: target.windowID,
                    displayID: target.displayID
                )
                && afterRestart.count > framesBeforeRestart
                && afterRestart.surfaceKinds == [.foregroundWindow]
                && afterRestart.releasedCount == afterRestart.count
                && finalState == .stoppedNoEligibleTarget
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    }

    private static func waitForFrames(
        _ counter: LM019FrameCounter,
        greaterThan minimum: Int
    ) async -> Bool {
        for _ in 0 ..< 50 {
            if counter.snapshot().count > minimum {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

private final class LM019FrameCounter: @unchecked Sendable {
    struct Snapshot {
        let count: Int
        let releasedCount: Int
        let surfaceKinds: Set<CaptureSurfaceKind>
    }

    private let lock = NSLock()
    private var count = 0
    private var releasedCount = 0
    private var surfaceKinds: Set<CaptureSurfaceKind> = []

    func accept(_ frame: ForegroundWindowPixelBuffer) {
        let surfaceKind = frame.surfaceKind
        frame.discardWithoutPersistence()
        lock.lock()
        count += 1
        surfaceKinds.insert(surfaceKind)
        if frame.isReleased {
            releasedCount += 1
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            count: count,
            releasedCount: releasedCount,
            surfaceKinds: surfaceKinds
        )
    }
}

private extension ScreenCaptureLifecycleState {
    var evidenceName: String {
        switch self {
        case .stoppedNoEligibleTarget:
            "stoppedNoEligibleTarget"
        case .permissionDenied:
            "permissionDenied"
        case let .refreshUnavailable(status):
            "refreshUnavailable:\(status.rawValue)"
        case let .running(windowID, displayID):
            "running:\(windowID):\(displayID)"
        case let .failed(message):
            "failed:\(message)"
        }
    }
}
