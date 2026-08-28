import AppKit
import CoreGraphics
import Foundation
import MemoryContracts

public protocol ActivityMonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemActivityMonotonicClock: ActivityMonotonicClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public enum ActivityInputClass: String, CaseIterable, Equatable, Sendable {
    case click
    case scroll
    case keyActivity
}

public struct ActivitySignal: Equatable, Sendable {
    public let inputClass: ActivityInputClass
    public let monotonicNanoseconds: UInt64

    public init(inputClass: ActivityInputClass, monotonicNanoseconds: UInt64) {
        self.inputClass = inputClass
        self.monotonicNanoseconds = monotonicNanoseconds
    }
}

public enum ActivityLifecycleEvent: String, CaseIterable, Equatable, Sendable {
    case willSleep
    case didWake
    case sessionLocked
    case sessionUnlocked
}

public enum ActivitySuspension: String, Equatable, Sendable {
    case sleep
    case sessionLocked
}

public struct ActivitySnapshot: Equatable, Sendable {
    public let activity: ActivityState
    public let suspension: ActivitySuspension?
    public let lastActivityNanoseconds: UInt64?
    public let lastInputClass: ActivityInputClass?

    public var acceptsCapture: Bool {
        suspension == nil && activity != .idle
    }
}

public actor ActivityMonitor {
    public static let activeWindowNanoseconds =
        CaptureConstants.activeAcceptanceIntervalNanoseconds
    public static let idleThresholdNanoseconds =
        CaptureConstants.idleSuspendIntervalNanoseconds

    private let clock: any ActivityMonotonicClock
    private var lastActivityNanoseconds: UInt64?
    private var lastInputClass: ActivityInputClass?
    private var isSleeping = false
    private var isSessionLocked = false

    public init(clock: any ActivityMonotonicClock = SystemActivityMonotonicClock()) {
        self.clock = clock
        lastActivityNanoseconds = clock.nowNanoseconds()
    }

    public func record(inputClass: ActivityInputClass) {
        record(
            ActivitySignal(
                inputClass: inputClass,
                monotonicNanoseconds: clock.nowNanoseconds()
            )
        )
    }

    public func record(_ signal: ActivitySignal) {
        guard suspension == nil else {
            return
        }
        if let lastActivityNanoseconds,
            signal.monotonicNanoseconds < lastActivityNanoseconds
        {
            return
        }
        lastActivityNanoseconds = signal.monotonicNanoseconds
        lastInputClass = signal.inputClass
    }

    public func handle(lifecycle event: ActivityLifecycleEvent) {
        switch event {
        case .willSleep:
            isSleeping = true
            requireFreshActivity()
        case .didWake:
            guard isSleeping else { return }
            isSleeping = false
            requireFreshActivity()
        case .sessionLocked:
            isSessionLocked = true
            requireFreshActivity()
        case .sessionUnlocked:
            guard isSessionLocked else { return }
            isSessionLocked = false
            requireFreshActivity()
        }
    }

    public func snapshot() -> ActivitySnapshot {
        let nowNanoseconds = clock.nowNanoseconds()
        return ActivitySnapshot(
            activity: activityState(at: nowNanoseconds),
            suspension: suspension,
            lastActivityNanoseconds: lastActivityNanoseconds,
            lastInputClass: lastInputClass
        )
    }

    private var suspension: ActivitySuspension? {
        if isSleeping { return .sleep }
        if isSessionLocked { return .sessionLocked }
        return nil
    }

    private func activityState(at nowNanoseconds: UInt64) -> ActivityState {
        guard suspension == nil, let lastActivityNanoseconds else {
            return .idle
        }
        let elapsed =
            nowNanoseconds >= lastActivityNanoseconds
            ? nowNanoseconds - lastActivityNanoseconds
            : 0
        if elapsed < Self.activeWindowNanoseconds {
            return .active
        }
        if elapsed < Self.idleThresholdNanoseconds {
            return .recentlyActive
        }
        return .idle
    }

    private func requireFreshActivity() {
        lastActivityNanoseconds = nil
        lastInputClass = nil
    }
}

public enum ActivityInputClassifier {
    public static func classify(_ eventType: CGEventType) -> ActivityInputClass? {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            .click
        case .scrollWheel:
            .scroll
        case .keyDown, .flagsChanged:
            .keyActivity
        default:
            nil
        }
    }
}

public final class SystemActivityEventTap: @unchecked Sendable {
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var handler: (@Sendable (ActivitySignal) -> Void)?

    public init() {}

    @discardableResult
    public func start(
        handler: @escaping @Sendable (ActivitySignal) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard eventTap == nil else {
            return true
        }
        self.handler = handler
        let eventTypes: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .keyDown,
            .flagsChanged,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, eventType in
            partial | (CGEventMask(1) << eventType.rawValue)
        }
        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: activityEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            self.handler = nil
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        let currentRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        runLoopSource = source
        runLoop = currentRunLoop
        return true
    }

    public func stop() {
        lock.lock()
        let eventTap = self.eventTap
        let source = runLoopSource
        let runLoop = self.runLoop
        self.eventTap = nil
        runLoopSource = nil
        self.runLoop = nil
        handler = nil
        lock.unlock()

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoop, let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
    }

    fileprivate func receive(_ eventType: CGEventType) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            let tap = lock.withLock { eventTap }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard let inputClass = ActivityInputClassifier.classify(eventType) else {
            return
        }
        let handler = lock.withLock { self.handler }
        handler?(
            ActivitySignal(
                inputClass: inputClass,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        )
    }

    deinit {
        stop()
    }
}

private func activityEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<SystemActivityEventTap>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
            .receive(type)
    }
    return Unmanaged.passUnretained(event)
}

public final class WorkspaceActivityLifecycleSource: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public static func classify(_ name: Notification.Name) -> ActivityLifecycleEvent? {
        switch name {
        case NSWorkspace.willSleepNotification:
            .willSleep
        case NSWorkspace.didWakeNotification:
            .didWake
        case NSWorkspace.sessionDidResignActiveNotification:
            .sessionLocked
        case NSWorkspace.sessionDidBecomeActiveNotification:
            .sessionUnlocked
        default:
            nil
        }
    }

    public func start(
        handler: @escaping @Sendable (ActivityLifecycleEvent) -> Void
    ) {
        lock.lock()
        guard observers.isEmpty else {
            lock.unlock()
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { notification in
                if let event = Self.classify(notification.name) {
                    handler(event)
                }
            }
        }
        lock.unlock()
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        let observers = lock.withLock { () -> [NSObjectProtocol] in
            defer { self.observers.removeAll() }
            return self.observers
        }
        observers.forEach(center.removeObserver)
    }

    deinit {
        stop()
    }
}

public final class SystemActivityMonitorController: @unchecked Sendable {
    public let monitor: ActivityMonitor
    private let eventTap: SystemActivityEventTap
    private let lifecycleSource: WorkspaceActivityLifecycleSource

    public init(
        monitor: ActivityMonitor = ActivityMonitor(),
        eventTap: SystemActivityEventTap = SystemActivityEventTap(),
        lifecycleSource: WorkspaceActivityLifecycleSource = WorkspaceActivityLifecycleSource()
    ) {
        self.monitor = monitor
        self.eventTap = eventTap
        self.lifecycleSource = lifecycleSource
    }

    @discardableResult
    public func start() -> Bool {
        lifecycleSource.start { [monitor] event in
            Task {
                await monitor.handle(lifecycle: event)
            }
        }
        let started = eventTap.start { [monitor] signal in
            Task {
                await monitor.record(signal)
            }
        }
        if !started {
            lifecycleSource.stop()
        }
        return started
    }

    public func stop() {
        eventTap.stop()
        lifecycleSource.stop()
    }
}
