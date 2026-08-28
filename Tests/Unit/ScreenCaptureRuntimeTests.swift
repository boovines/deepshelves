import CoreVideo
import MemoryCapture
import XCTest

final class ScreenCaptureRuntimeTests: XCTestCase {
    func testLifecycleStartsWithoutAnEligibleTargetAndCreatesNoStream() async throws {
        let permission = FakeScreenRecordingPermissionProbe(.granted)
        let refresher = FakeShareableWindowRefresher(targets: [Self.target])
        let driver = FakeForegroundWindowStreamDriver()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permission,
            refresher: refresher,
            streamDriver: driver
        )

        let initialState = await lifecycle.state
        XCTAssertEqual(initialState, .stoppedNoEligibleTarget)
        await lifecycle.reconcile(targetWindowID: nil)

        let reconciledState = await lifecycle.state
        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(reconciledState, .stoppedNoEligibleTarget)
        XCTAssertEqual(driverSnapshot, .init(startedWindowIDs: [], stopCount: 0))
    }

    func testPermissionGrantRevokeAndRegrantRestartsOnlyTheForegroundWindowStream() async throws {
        let permission = FakeScreenRecordingPermissionProbe(.granted)
        let refresher = FakeShareableWindowRefresher(targets: [Self.target])
        let driver = FakeForegroundWindowStreamDriver()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permission,
            refresher: refresher,
            streamDriver: driver
        )

        await lifecycle.reconcile(targetWindowID: Self.target.windowID)
        let grantedState = await lifecycle.state
        XCTAssertEqual(
            grantedState,
            .running(windowID: Self.target.windowID, displayID: Self.target.displayID)
        )

        await permission.set(.denied)
        await lifecycle.reconcile(targetWindowID: Self.target.windowID)
        let deniedState = await lifecycle.state
        XCTAssertEqual(deniedState, .permissionDenied)

        await permission.set(.granted)
        await lifecycle.reconcile(targetWindowID: Self.target.windowID)
        let regrantedState = await lifecycle.state
        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(
            regrantedState,
            .running(windowID: Self.target.windowID, displayID: Self.target.displayID)
        )
        XCTAssertEqual(
            driverSnapshot,
            .init(
                startedWindowIDs: [Self.target.windowID, Self.target.windowID],
                stopCount: 1
            )
        )
    }

    func testDisplayChangeStopsRefreshesAndRestartsTheSameEligibleWindow() async throws {
        let permission = FakeScreenRecordingPermissionProbe(.granted)
        let refresher = FakeShareableWindowRefresher(targets: [Self.target])
        let driver = FakeForegroundWindowStreamDriver()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permission,
            refresher: refresher,
            streamDriver: driver
        )

        await lifecycle.reconcile(targetWindowID: Self.target.windowID)
        await lifecycle.restartAfterDisplayChange(targetWindowID: Self.target.windowID)

        let refreshCount = await refresher.refreshCount
        let driverSnapshot = await driver.snapshot()
        let state = await lifecycle.state
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(
            driverSnapshot,
            .init(
                startedWindowIDs: [Self.target.windowID, Self.target.windowID],
                stopCount: 1
            )
        )
        XCTAssertEqual(
            state,
            .running(windowID: Self.target.windowID, displayID: Self.target.displayID)
        )
    }

    func testRepeatedReconcileKeepsOneLongLivedStreamForTheSameTarget() async throws {
        let permission = FakeScreenRecordingPermissionProbe(.granted)
        let refresher = FakeShareableWindowRefresher(targets: [Self.target])
        let driver = FakeForegroundWindowStreamDriver()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permission,
            refresher: refresher,
            streamDriver: driver
        )

        await lifecycle.reconcile(targetWindowID: Self.target.windowID)
        await lifecycle.reconcile(targetWindowID: Self.target.windowID)

        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(
            driverSnapshot,
            .init(startedWindowIDs: [Self.target.windowID], stopCount: 0)
        )
    }

    func testMissingTargetAfterRefreshStopsWithoutFallingBackToADisplay() async throws {
        let permission = FakeScreenRecordingPermissionProbe(.granted)
        let refresher = FakeShareableWindowRefresher(targets: [Self.target])
        let driver = FakeForegroundWindowStreamDriver()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permission,
            refresher: refresher,
            streamDriver: driver
        )

        await lifecycle.reconcile(targetWindowID: Self.target.windowID)
        await refresher.setTargets([])
        await lifecycle.restartAfterDisplayChange(targetWindowID: Self.target.windowID)

        let state = await lifecycle.state
        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(state, .stoppedNoEligibleTarget)
        XCTAssertEqual(
            driverSnapshot,
            .init(startedWindowIDs: [Self.target.windowID], stopCount: 1)
        )
    }

    func testTimedOutRefreshSuppressesDuplicatesAndRejectsLateCompletionAfterReplacement() throws {
        var gate = ShareableContentRefreshLeaseGate()
        let first = try XCTUnwrap(gate.begin(nowNanoseconds: 0, cooldownNanoseconds: 30))
        gate.markTimedOut(first)

        XCTAssertNil(gate.begin(nowNanoseconds: 29, cooldownNanoseconds: 30))
        let replacement = try XCTUnwrap(
            gate.begin(nowNanoseconds: 30, cooldownNanoseconds: 30)
        )
        XCTAssertFalse(gate.acceptCompletion(first))
        XCTAssertTrue(gate.acceptCompletion(replacement))
    }

    func testPixelBufferIsForegroundWindowOnlyAndReleasedAfterMediaCommit() throws {
        var rawBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_32BGRA,
                nil,
                &rawBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(rawBuffer)
        let lease = ForegroundWindowPixelBuffer(
            pixelBuffer: buffer,
            targetWindowID: Self.target.windowID,
            capturedNanoseconds: 1_000
        )

        XCTAssertEqual(lease.surfaceKind, .foregroundWindow)
        XCTAssertFalse(lease.isReleased)
        let width = try lease.withPixelBufferForMediaCommit { value in
            CVPixelBufferGetWidth(value)
        }

        XCTAssertEqual(width, 16)
        XCTAssertTrue(lease.isReleased)
        XCTAssertThrowsError(try lease.withPixelBufferForMediaCommit { _ in () })
    }

    func testRefreshFailureCannotDeliverOrPersistAnyPixel() async throws {
        let permission = FakeScreenRecordingPermissionProbe(.granted)
        let refresher = FakeShareableWindowRefresher(
            result: .init(status: .timedOut, targets: [])
        )
        let driver = FakeForegroundWindowStreamDriver()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permission,
            refresher: refresher,
            streamDriver: driver
        )

        await lifecycle.reconcile(targetWindowID: Self.target.windowID)

        let state = await lifecycle.state
        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(state, .refreshUnavailable(.timedOut))
        XCTAssertEqual(driverSnapshot, .init(startedWindowIDs: [], stopCount: 0))
    }

    func testIneligibleWindowCannotStartAStream() async throws {
        let ineligible = ForegroundWindowCaptureTarget.fixture(
            windowID: 42,
            processID: 99,
            displayID: 0,
            width: 800,
            height: 600,
            isEligibleForegroundWindow: false
        )
        let permission = FakeScreenRecordingPermissionProbe(.granted)
        let refresher = FakeShareableWindowRefresher(targets: [ineligible])
        let driver = FakeForegroundWindowStreamDriver()
        let lifecycle = ScreenCaptureLifecycleController(
            permissionProbe: permission,
            refresher: refresher,
            streamDriver: driver
        )

        await lifecycle.reconcile(targetWindowID: ineligible.windowID)

        let state = await lifecycle.state
        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(state, .stoppedNoEligibleTarget)
        XCTAssertEqual(driverSnapshot, .init(startedWindowIDs: [], stopCount: 0))
    }

    private static let target = ForegroundWindowCaptureTarget.fixture(
        windowID: 41,
        processID: 99,
        displayID: 1,
        width: 800,
        height: 600
    )
}

private actor FakeScreenRecordingPermissionProbe: ScreenRecordingPermissionProbing {
    private var permission: ScreenRecordingPermission

    init(_ permission: ScreenRecordingPermission) {
        self.permission = permission
    }

    func currentPermission() -> ScreenRecordingPermission {
        permission
    }

    func set(_ permission: ScreenRecordingPermission) {
        self.permission = permission
    }
}

private actor FakeShareableWindowRefresher: ShareableWindowRefreshing {
    private var result: ShareableWindowRefreshResult
    private(set) var refreshCount = 0

    init(targets: [ForegroundWindowCaptureTarget]) {
        result = ShareableWindowRefreshResult(status: .available, targets: targets)
    }

    init(result: ShareableWindowRefreshResult) {
        self.result = result
    }

    func refresh() -> ShareableWindowRefreshResult {
        refreshCount += 1
        return result
    }

    func setTargets(_ targets: [ForegroundWindowCaptureTarget]) {
        result = ShareableWindowRefreshResult(status: .available, targets: targets)
    }
}

private actor FakeForegroundWindowStreamDriver: ForegroundWindowStreamDriving {
    struct Snapshot: Equatable {
        let startedWindowIDs: [UInt32]
        let stopCount: Int
    }

    private var startedWindowIDs: [UInt32] = []
    private var stopCount = 0

    func start(
        target: ForegroundWindowCaptureTarget,
        frameHandler _: @escaping @Sendable (ForegroundWindowPixelBuffer) -> Void
    ) async throws {
        startedWindowIDs.append(target.windowID)
    }

    func stop() async {
        stopCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(startedWindowIDs: startedWindowIDs, stopCount: stopCount)
    }
}
