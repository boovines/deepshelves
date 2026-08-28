import Foundation
import MemoryCapture
import MemoryContracts
import MemoryStore
import Testing

@Suite("LM-009 application lifecycle")
struct AppLifecycleTests {
    @Test("Every fake runtime state has an exact menu projection")
    func menuProjectionMatchesRuntimeState() {
        let expectations: [LocalMemoryRuntimeStatus: RuntimeMenuProjection] = [
            .recording: RuntimeMenuProjection(
                statusLabel: "Recording",
                statusSymbol: "record.circle",
                primaryActionLabel: "Pause Recording"
            ),
            .paused: RuntimeMenuProjection(
                statusLabel: "Paused",
                statusSymbol: "pause.circle",
                primaryActionLabel: "Resume Recording"
            ),
            .idle: RuntimeMenuProjection(
                statusLabel: "Idle",
                statusSymbol: "moon.zzz",
                primaryActionLabel: "Pause Recording"
            ),
            .sleeping: RuntimeMenuProjection(
                statusLabel: "Recording asleep",
                statusSymbol: "powersleep",
                primaryActionLabel: "Pause Recording"
            ),
            .targetUnavailable: RuntimeMenuProjection(
                statusLabel: "Waiting for a foreground window",
                statusSymbol: "rectangle.slash",
                primaryActionLabel: "Pause Recording"
            ),
            .permissionRequired: RuntimeMenuProjection(
                statusLabel: "Recording unavailable",
                statusSymbol: "exclamationmark.triangle",
                primaryActionLabel: "Review Permissions…"
            ),
            .diskFull: RuntimeMenuProjection(
                statusLabel: "Recording unavailable",
                statusSymbol: "externaldrive.badge.exclamationmark",
                primaryActionLabel: "Manage Storage…"
            ),
            .stopped: RuntimeMenuProjection(
                statusLabel: "Recording stopped",
                statusSymbol: "stop.circle",
                primaryActionLabel: "Review Status…"
            ),
            .indexing: RuntimeMenuProjection(
                statusLabel: "Indexing",
                statusSymbol: "arrow.triangle.2.circlepath",
                primaryActionLabel: "Pause Recording"
            ),
        ]

        #expect(Set(expectations.keys) == Set(LocalMemoryRuntimeStatus.allCases))
        for status in LocalMemoryRuntimeStatus.allCases {
            #expect(status.menuProjection == expectations[status])
        }
    }

    @Test("A relaunch restores runtime state but never restores a main window implicitly")
    func relaunchRestoresOnlyRuntimeState() async throws {
        let stateURL = temporaryStateURL()
        let first = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )

        let firstLaunch = try await first.launch(initialStatus: .recording)
        #expect(firstLaunch.status == .recording)
        #expect(firstLaunch.launchCount == 1)
        #expect(firstLaunch.mainWindowVisible == false)

        _ = try await first.setMainWindowVisible(true)
        _ = try await first.transition(to: .paused)

        let relaunched = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )
        let secondLaunch = try await relaunched.launch(initialStatus: .diskFull)
        #expect(secondLaunch.status == .paused)
        #expect(secondLaunch.launchCount == 2)
        #expect(secondLaunch.mainWindowVisible == false)

        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Pause toggling is deterministic and unavailable states do not pretend to resume")
    func pauseToggleBehavior() async throws {
        let lifecycle = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: temporaryStateURL())
        )
        _ = try await lifecycle.launch(initialStatus: .recording)
        #expect(try await lifecycle.performPrimaryAction().status == .paused)
        #expect(try await lifecycle.performPrimaryAction().status == .recording)
        _ = try await lifecycle.transition(to: .indexing)
        #expect(try await lifecycle.performPrimaryAction().status == .paused)
        _ = try await lifecycle.transition(to: .permissionRequired)
        #expect(try await lifecycle.performPrimaryAction().status == .permissionRequired)
        _ = try await lifecycle.transition(to: .diskFull)
        #expect(try await lifecycle.performPrimaryAction().status == .diskFull)
    }

    @Test("Corrupt state fails closed without presenting a window")
    func corruptStateFailsClosed() async throws {
        let stateURL = temporaryStateURL()
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: stateURL)

        let lifecycle = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )
        let snapshot = try await lifecycle.launch(initialStatus: .recording)
        #expect(snapshot.status == .permissionRequired)
        #expect(snapshot.mainWindowVisible == false)
        #expect(snapshot.recoveryReason == .invalidPersistedState)
    }

    @Test("Normal launch is explicitly menu-bar only")
    func defaultLaunchHasNoMainWindow() {
        #expect(AppLifecycleDefaults.opensMainWindowAtLaunch == false)
    }

    @Test("Capture lifecycle is fail closed and projects every unavailable cause")
    func captureLifecycleCauseMatrix() async throws {
        let target = ShareableWindowDescriptor(
            windowID: 42,
            processID: 7,
            bounds: PointRect(x: 0, y: 0, width: 800, height: 600),
            title: "Approved fixture",
            isOnScreen: true,
            isNormalContent: true,
            intersectsMainDisplay: true
        )
        let ready = CaptureLifecycleInputs(
            recordingEnabled: true,
            permissionGranted: true,
            activity: .active,
            suspension: nil,
            targetResolution: .approved(target),
            storageAvailable: true,
            filterHealthy: true,
            databaseHealthy: true,
            processRunning: true
        )
        let cases: [(CaptureLifecycleInputs, CaptureLifecycleCause, RecordingGapReason?)] = [
            (ready.replacing(recordingEnabled: false), .paused, .paused),
            (ready.replacing(activity: .idle), .idle, .idle),
            (ready.replacing(suspension: .sleep), .sleep, .sleep),
            (ready.replacing(suspension: .sessionLocked), .sessionLocked, .sleep),
            (ready.replacing(permissionGranted: false), .permissionLost, .permissionLost),
            (ready.replacing(storageAvailable: false), .lowDisk, .processStopped),
            (ready.replacing(filterHealthy: false), .filterFailed, .filterFailed),
            (ready.replacing(databaseHealthy: false), .databaseFailure, .processStopped),
            (ready.replacing(processRunning: false), .processStopped, .processStopped),
            (
                ready.replacing(targetResolution: .gap(.ambiguousWindow)),
                .targetUnavailable(.ambiguousWindow),
                .ambiguousWindow
            ),
        ]

        for (inputs, expectedCause, expectedGap) in cases {
            let coordinator = CaptureLifecycleCoordinator()
            let snapshot = try await coordinator.reconcile(
                inputs,
                observedAt: Date(timeIntervalSince1970: 1),
                observedAtNanoseconds: 1
            )
            #expect(snapshot.cause == expectedCause)
            #expect(snapshot.timelineGapReason == expectedGap)
            #expect(snapshot.captureAllowed == false)
            #expect(snapshot.activeTargetWindowID == nil)
            #expect(snapshot.privacyModeLabel == "Foreground window only")
        }

        let coordinator = CaptureLifecycleCoordinator()
        let active = try await coordinator.reconcile(
            ready,
            observedAt: Date(timeIntervalSince1970: 2),
            observedAtNanoseconds: 2
        )
        #expect(active.cause == .ready)
        #expect(active.captureAllowed)
        #expect(active.activeTargetWindowID == 42)
        #expect(active.timelineGapReason == nil)

        let targetCases: [(CaptureGapReason, RecordingGapReason)] = [
            (.unresolvedWindow, .unresolvedWindow),
            (.ambiguousWindow, .ambiguousWindow),
            (.minimizedWindow, .minimizedWindow),
            (.unsupportedDisplay, .unsupportedDisplay),
            (.protectedSurface, .protectedSurface),
            (.noWindow, .noWindow),
        ]
        for (captureReason, recordingReason) in targetCases {
            let unavailable = try await CaptureLifecycleCoordinator().reconcile(
                ready.replacing(targetResolution: .gap(captureReason)),
                observedAt: Date(timeIntervalSince1970: 3),
                observedAtNanoseconds: 3
            )
            #expect(unavailable.cause == .targetUnavailable(captureReason))
            #expect(unavailable.timelineGapReason == recordingReason)
            #expect(!unavailable.captureAllowed)
        }
    }

    @Test("Cause changes persist exact typed gaps and UI projection remains under 250 ms")
    func lifecycleGapAndProjectionTiming() async throws {
        let clock = FakeCaptureLifecycleClock(nowNanoseconds: 10)
        let sink = RecordingGapCollector()
        let coordinator = CaptureLifecycleCoordinator(clock: clock, gapSink: sink)
        let paused = CaptureLifecycleInputs(
            recordingEnabled: false,
            permissionGranted: true,
            activity: .active,
            suspension: nil,
            targetResolution: .gap(.noWindow),
            storageAvailable: true,
            filterHealthy: true,
            databaseHealthy: true,
            processRunning: true
        )

        _ = try await coordinator.reconcile(
            paused,
            observedAt: Date(timeIntervalSince1970: 10),
            observedAtNanoseconds: 10
        )
        clock.nowNanoseconds = 200_000_010
        let permission = try await coordinator.reconcile(
            paused.replacing(recordingEnabled: true, permissionGranted: false),
            observedAt: Date(timeIntervalSince1970: 11),
            observedAtNanoseconds: 10
        )

        #expect(permission.projectionLatencyNanoseconds == 200_000_000)
        #expect(
            permission.projectionLatencyNanoseconds
                <= CaptureLifecycleCoordinator.uiBudgetNanoseconds)
        let gaps = await sink.gaps
        #expect(gaps.count == 1)
        #expect(gaps.first?.reason == .paused)
        #expect(gaps.first?.approvedBundleID == nil)
    }

    @Test("A recording relaunch fails closed as process stopped until inputs reconcile")
    func recordingRelaunchFailsClosed() async throws {
        let stateURL = temporaryStateURL()
        let first = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )
        _ = try await first.launch(initialStatus: .recording)

        let relaunched = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )
        let snapshot = try await relaunched.launch(initialStatus: .recording)
        #expect(snapshot.status == .stopped)
        #expect(snapshot.recoveryReason == .interruptedCapture)
        #expect(snapshot.interruptedAt != nil)
        #expect(snapshot.status.menuProjection.statusLabel == "Recording stopped")
    }

    @Test("Completed lifecycle gaps persist in the encrypted archive interval table")
    func completedGapsPersistInArchive() async throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let clock = FakeCaptureLifecycleClock(nowNanoseconds: 1)
        let coordinator = CaptureLifecycleCoordinator(clock: clock, gapSink: archive)
        let paused = CaptureLifecycleInputs.failClosed.replacing(
            recordingEnabled: false,
            processRunning: true
        )
        _ = try await coordinator.reconcile(
            paused,
            observedAt: Date(timeIntervalSince1970: 1),
            observedAtNanoseconds: 1
        )
        _ = try await coordinator.reconcile(
            paused.replacing(recordingEnabled: true),
            observedAt: Date(timeIntervalSince1970: 2),
            observedAtNanoseconds: 1
        )

        let gaps = try archive.recordedLifecycleGaps()
        #expect(gaps.count == 1)
        #expect(gaps.first?.reason == .paused)
        #expect(gaps.first?.approvedBundleID == nil)
    }

    @Test("Existing activity, target, permission, and stream states compose without hidden capture")
    func existingSubsystemsComposeFailClosed() async throws {
        let target = ShareableWindowDescriptor(
            windowID: 42,
            processID: 7,
            bounds: PointRect(x: 0, y: 0, width: 800, height: 600),
            title: "Approved fixture",
            isOnScreen: true,
            isNormalContent: true,
            intersectsMainDisplay: true
        )
        let activity = ActivitySnapshot(
            activity: .active,
            suspension: nil,
            lastActivityNanoseconds: 1,
            lastInputClass: .click
        )
        let ready = CaptureLifecycleInputs(
            recordingEnabled: true,
            permission: .granted,
            activitySnapshot: activity,
            targetResolution: .approved(target),
            screenCaptureState: .running(windowID: 42, displayID: 1),
            storageAvailable: true,
            databaseHealthy: true,
            processRunning: true
        )
        let allowed = try await CaptureLifecycleCoordinator().reconcile(
            ready,
            observedAt: Date(timeIntervalSince1970: 1),
            observedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        #expect(allowed.captureAllowed)

        let staleStream = CaptureLifecycleInputs(
            recordingEnabled: true,
            permission: .granted,
            activitySnapshot: activity,
            targetResolution: .approved(target),
            screenCaptureState: .running(windowID: 99, displayID: 1),
            storageAvailable: true,
            databaseHealthy: true,
            processRunning: true
        )
        let denied = try await CaptureLifecycleCoordinator().reconcile(
            staleStream,
            observedAt: Date(timeIntervalSince1970: 2),
            observedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        #expect(!denied.captureAllowed)
        #expect(denied.timelineGapReason == .unresolvedWindow)
    }

    @Test("Restart restoration closes one process-stopped gap after healthy reconciliation")
    func restartRestorationClosesProcessStoppedGap() async throws {
        let sink = RecordingGapCollector()
        let clock = FakeCaptureLifecycleClock(nowNanoseconds: 20)
        let coordinator = CaptureLifecycleCoordinator(clock: clock, gapSink: sink)
        await coordinator.restoreOpenGap(
            reason: .processStopped,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let target = ShareableWindowDescriptor(
            windowID: 42,
            processID: 7,
            bounds: PointRect(x: 0, y: 0, width: 800, height: 600),
            title: nil,
            isOnScreen: true,
            isNormalContent: true,
            intersectsMainDisplay: true
        )
        let ready = CaptureLifecycleInputs(
            recordingEnabled: true,
            permissionGranted: true,
            activity: .active,
            suspension: nil,
            targetResolution: .approved(target),
            storageAvailable: true,
            filterHealthy: true,
            databaseHealthy: true,
            processRunning: true
        )
        let snapshot = try await coordinator.reconcile(
            ready,
            observedAt: Date(timeIntervalSince1970: 20),
            observedAtNanoseconds: 20
        )

        #expect(snapshot.captureAllowed)
        let gaps = await sink.gaps
        #expect(gaps.count == 1)
        #expect(gaps.first?.reason == .processStopped)
        #expect(gaps.first?.startedAt == Date(timeIntervalSince1970: 10))
        #expect(gaps.first?.endedAt == Date(timeIntervalSince1970: 20))
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "runtime-state.json")
    }
}

private final class FakeCaptureLifecycleClock: CaptureLifecycleClock, @unchecked Sendable {
    var nowNanoseconds: UInt64

    init(nowNanoseconds: UInt64) {
        self.nowNanoseconds = nowNanoseconds
    }
}

private actor RecordingGapCollector: RecordingGapPersisting {
    private(set) var gaps: [RecordingGap] = []

    func persist(recordingGap: RecordingGap) async throws {
        gaps.append(recordingGap)
    }
}
