import AppKit
import CoreGraphics
import Foundation
import MemoryCapture
import MemoryContracts
import XCTest

final class ActivityMonitorTests: XCTestCase {
    func testFakeClockTransitionsAtExactActiveAndFiveMinuteBoundaries() async throws {
        let configuration = try loadFixtureConfiguration()
        let clock = FakeActivityClock(nowNanoseconds: 10_000)
        let monitor = ActivityMonitor(clock: clock)

        let initial = await monitor.snapshot()
        XCTAssertEqual(initial.activity, .active)
        clock.advance(by: configuration.activeWindowNanoseconds)
        let recentlyActive = await monitor.snapshot()
        XCTAssertEqual(recentlyActive.activity, .recentlyActive)
        clock.set(10_000 + configuration.idleThresholdNanoseconds - 1)
        let nearlyIdle = await monitor.snapshot()
        XCTAssertEqual(nearlyIdle.activity, .recentlyActive)
        clock.advance(by: 1)
        let idle = await monitor.snapshot()
        XCTAssertEqual(idle.activity, .idle)
        XCTAssertFalse(idle.acceptsCapture)
    }

    func testEveryCoarseInputClassRecoversFromIdleWithoutPayload() async throws {
        let configuration = try loadFixtureConfiguration()

        for (index, inputClass) in ActivityInputClass.allCases.enumerated() {
            let clock = FakeActivityClock(
                nowNanoseconds: UInt64(index) * 1_000_000_000
            )
            let monitor = ActivityMonitor(clock: clock)
            clock.advance(by: configuration.idleThresholdNanoseconds)
            let idle = await monitor.snapshot()
            XCTAssertEqual(idle.activity, .idle)

            await monitor.record(inputClass: inputClass)
            let recovered = await monitor.snapshot()
            XCTAssertEqual(recovered.activity, .active)
            XCTAssertEqual(recovered.lastInputClass, inputClass)
            XCTAssertEqual(recovered.lastActivityNanoseconds, clock.nowNanoseconds())
            XCTAssertTrue(recovered.acceptsCapture)
        }
        XCTAssertEqual(ActivityInputClass.allCases.map(\.rawValue), configuration.inputClasses)
        XCTAssertEqual(
            Mirror(
                reflecting: ActivitySignal(
                    inputClass: .keyActivity,
                    monotonicNanoseconds: 42
                )
            ).children.compactMap(\.label),
            ["inputClass", "monotonicNanoseconds"]
        )
    }

    func testSleepIgnoresInputAndWakeRemainsIdleUntilFreshActivity() async throws {
        let clock = FakeActivityClock(nowNanoseconds: 1_000)
        let monitor = ActivityMonitor(clock: clock)

        await monitor.handle(lifecycle: .willSleep)
        let sleeping = await monitor.snapshot()
        XCTAssertEqual(sleeping.suspension, .sleep)
        XCTAssertFalse(sleeping.acceptsCapture)
        clock.advance(by: 1_000)
        await monitor.record(inputClass: .keyActivity)
        let ignoredInput = await monitor.snapshot()
        XCTAssertNil(ignoredInput.lastInputClass)

        await monitor.handle(lifecycle: .didWake)
        let woke = await monitor.snapshot()
        XCTAssertNil(woke.suspension)
        XCTAssertEqual(woke.activity, .idle)
        XCTAssertFalse(woke.acceptsCapture)

        await monitor.record(inputClass: .click)
        let recovered = await monitor.snapshot()
        XCTAssertEqual(recovered.activity, .active)
        XCTAssertTrue(recovered.acceptsCapture)
    }

    func testSessionLockIgnoresInputAndUnlockRequiresFreshActivity() async throws {
        let clock = FakeActivityClock(nowNanoseconds: 2_000)
        let monitor = ActivityMonitor(clock: clock)

        await monitor.handle(lifecycle: .sessionLocked)
        let locked = await monitor.snapshot()
        XCTAssertEqual(locked.suspension, .sessionLocked)
        clock.advance(by: 1_000)
        await monitor.record(inputClass: .scroll)
        let ignoredInput = await monitor.snapshot()
        XCTAssertNil(ignoredInput.lastInputClass)

        await monitor.handle(lifecycle: .sessionUnlocked)
        let unlocked = await monitor.snapshot()
        XCTAssertEqual(unlocked.activity, .idle)
        XCTAssertFalse(unlocked.acceptsCapture)
        await monitor.record(inputClass: .scroll)
        let recovered = await monitor.snapshot()
        XCTAssertEqual(recovered.activity, .active)
    }

    func testSleepAndLockPrecedenceCannotAccidentallyResumeCapture() async throws {
        let clock = FakeActivityClock(nowNanoseconds: 3_000)
        let monitor = ActivityMonitor(clock: clock)

        await monitor.handle(lifecycle: .sessionLocked)
        await monitor.handle(lifecycle: .willSleep)
        let sleeping = await monitor.snapshot()
        XCTAssertEqual(sleeping.suspension, .sleep)
        await monitor.handle(lifecycle: .didWake)
        let wokeLocked = await monitor.snapshot()
        XCTAssertEqual(wokeLocked.suspension, .sessionLocked)
        await monitor.handle(lifecycle: .sessionUnlocked)
        let unlocked = await monitor.snapshot()
        XCTAssertNil(unlocked.suspension)
        XCTAssertEqual(unlocked.activity, .idle)

        await monitor.record(inputClass: .click)
        await monitor.handle(lifecycle: .didWake)
        await monitor.handle(lifecycle: .sessionUnlocked)
        let afterDuplicateResume = await monitor.snapshot()
        XCTAssertEqual(afterDuplicateResume.activity, .active)
        XCTAssertEqual(afterDuplicateResume.lastInputClass, .click)
    }

    func testOutOfOrderSignalsCannotMoveLastActivityBackward() async throws {
        let clock = FakeActivityClock(nowNanoseconds: 50_000)
        let monitor = ActivityMonitor(clock: clock)
        await monitor.record(
            ActivitySignal(inputClass: .click, monotonicNanoseconds: 50_000)
        )
        await monitor.record(
            ActivitySignal(inputClass: .keyActivity, monotonicNanoseconds: 49_999)
        )

        let snapshot = await monitor.snapshot()
        XCTAssertEqual(snapshot.lastActivityNanoseconds, 50_000)
        XCTAssertEqual(snapshot.lastInputClass, .click)
    }

    func testSystemClassifiersMapOnlyCoarseEventAndLifecycleClasses() throws {
        XCTAssertEqual(ActivityInputClassifier.classify(.leftMouseDown), .click)
        XCTAssertEqual(ActivityInputClassifier.classify(.rightMouseDown), .click)
        XCTAssertEqual(ActivityInputClassifier.classify(.otherMouseDown), .click)
        XCTAssertEqual(ActivityInputClassifier.classify(.scrollWheel), .scroll)
        XCTAssertEqual(ActivityInputClassifier.classify(.keyDown), .keyActivity)
        XCTAssertEqual(ActivityInputClassifier.classify(.flagsChanged), .keyActivity)
        XCTAssertNil(ActivityInputClassifier.classify(.mouseMoved))

        XCTAssertEqual(
            WorkspaceActivityLifecycleSource.classify(NSWorkspace.willSleepNotification),
            .willSleep
        )
        XCTAssertEqual(
            WorkspaceActivityLifecycleSource.classify(NSWorkspace.didWakeNotification),
            .didWake
        )
        XCTAssertEqual(
            WorkspaceActivityLifecycleSource.classify(
                NSWorkspace.sessionDidResignActiveNotification
            ),
            .sessionLocked
        )
        XCTAssertEqual(
            WorkspaceActivityLifecycleSource.classify(
                NSWorkspace.sessionDidBecomeActiveNotification
            ),
            .sessionUnlocked
        )
    }

    func testWorkspaceSourceEmitsAndStopsAllLifecycleNotifications() throws {
        let recorder = LockedLifecycleRecorder()
        let expectation = expectation(description: "all workspace lifecycle notifications")
        expectation.expectedFulfillmentCount = 4
        let source = WorkspaceActivityLifecycleSource()
        source.start { event in
            recorder.append(event)
            expectation.fulfill()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(
            recorder.events,
            [.willSleep, .didWake, .sessionLocked, .sessionUnlocked]
        )

        source.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(recorder.events.count, 4)
    }

    func testShippingActivitySourceContainsNoSensitiveInputAccessorsOrPayloadFields() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Packages/MemoryCapture/Sources/MemoryCapture/ActivityMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let forbiddenTerms = [
            "NSPasteboard",
            "kCGKeyboardEventKeycode",
            "CGEventKeyboardGetUnicodeString",
            "keyCode",
            "characters",
            "clipboard",
            "mouseLocation",
            "CGEventGetIntegerValueField",
        ]
        for term in forbiddenTerms {
            XCTAssertFalse(source.contains(term), term)
        }
        let configuration = try loadFixtureConfiguration()
        XCTAssertEqual(configuration.rawKeyPayloadFieldCount, 0)
        XCTAssertEqual(configuration.clipboardPayloadFieldCount, 0)
        XCTAssertEqual(configuration.cursorPayloadFieldCount, 0)
    }

    private func loadFixtureConfiguration() throws -> LM023FixtureConfiguration {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM023/activity-state-timeline.json")
        return try JSONDecoder().decode(
            LM023FixtureConfiguration.self,
            from: Data(contentsOf: sourceURL)
        )
    }
}

private struct LM023FixtureConfiguration: Decodable {
    let seed: UInt64
    let activeWindowNanoseconds: UInt64
    let idleThresholdNanoseconds: UInt64
    let inputClasses: [String]
    let lifecycleEvents: [String]
    let rawKeyPayloadFieldCount: Int
    let clipboardPayloadFieldCount: Int
    let cursorPayloadFieldCount: Int
}

private final class FakeActivityClock: ActivityMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(nowNanoseconds: UInt64) {
        value = nowNanoseconds
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock { value }
    }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }

    func set(_ nanoseconds: UInt64) {
        lock.withLock { value = nanoseconds }
    }
}

private final class LockedLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ActivityLifecycleEvent] = []

    var events: [ActivityLifecycleEvent] {
        lock.withLock { storage }
    }

    func append(_ event: ActivityLifecycleEvent) {
        lock.withLock { storage.append(event) }
    }
}
