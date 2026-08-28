import ApplicationServices
import Foundation

public struct AccessibilitySnapshotTarget: Equatable, Sendable {
    public let captureEpochID: UUID
    public let windowID: UInt32
    public let processID: Int32
    public let bounds: PointRect
    public let title: String?

    public init(
        captureEpochID: UUID,
        windowID: UInt32,
        processID: Int32,
        bounds: PointRect,
        title: String?
    ) {
        self.captureEpochID = captureEpochID
        self.windowID = windowID
        self.processID = processID
        self.bounds = bounds
        self.title = title
    }
}

public struct AccessibilityObservedWindow: Equatable, Sendable {
    public let processID: Int32
    public let bounds: PointRect
    public let title: String?

    public init(processID: Int32, bounds: PointRect, title: String?) {
        self.processID = processID
        self.bounds = bounds
        self.title = title
    }
}

public struct AccessibilitySnapshotLimits: Equatable, Sendable {
    public let maximumNodes: Int
    public let maximumDepth: Int
    public let maximumStringLength: Int
    public let timeBudgetMilliseconds: Double

    public init(
        maximumNodes: Int = 256,
        maximumDepth: Int = 12,
        maximumStringLength: Int = 512,
        timeBudgetMilliseconds: Double = 45
    ) {
        self.maximumNodes = max(1, maximumNodes)
        self.maximumDepth = max(0, maximumDepth)
        self.maximumStringLength = max(1, maximumStringLength)
        self.timeBudgetMilliseconds = min(49, max(1, timeBudgetMilliseconds))
    }

    fileprivate var timeBudgetNanoseconds: UInt64 {
        UInt64(timeBudgetMilliseconds * 1_000_000)
    }
}

public protocol AccessibilitySnapshotNode: AnyObject {
    var role: String { get }
    var subrole: String? { get }
    var title: String? { get }
    var value: String? { get }
    var nodeDescription: String? { get }
    var help: String? { get }
    var identifier: String? { get }
    var bounds: PointRect? { get }
    var isEnabled: Bool? { get }
    var isFocused: Bool? { get }
    func children(maximumCount: Int) -> (
        nodes: [any AccessibilitySnapshotNode], wasTruncated: Bool
    )
}

public struct ProjectedAccessibilityElement: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let nodeDescription: String?
    public let help: String?
    public let identifier: String?
    public let bounds: PointRect?
    public let isEnabled: Bool?
    public let isFocused: Bool?
    public let hierarchyPath: [Int]
    public let signature: String

    public init(
        role: String,
        subrole: String?,
        title: String?,
        value: String?,
        nodeDescription: String?,
        help: String?,
        identifier: String?,
        bounds: PointRect?,
        isEnabled: Bool?,
        isFocused: Bool?,
        hierarchyPath: [Int],
        signature: String
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.nodeDescription = nodeDescription
        self.help = help
        self.identifier = identifier
        self.bounds = bounds
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.hierarchyPath = hierarchyPath
        self.signature = signature
    }
}

public enum AccessibilitySnapshotStatus: String, Equatable, Sendable {
    case useful
    case empty
    case timedOut
    case permissionDenied
    case targetUnavailable
    case targetMismatch
}

public struct AccessibilitySnapshot: Equatable, Sendable {
    public let status: AccessibilitySnapshotStatus
    public let target: AccessibilitySnapshotTarget
    public let elements: [ProjectedAccessibilityElement]
    public let nodesVisited: Int
    public let wasTruncated: Bool
    public let elapsedMilliseconds: Double

    public var isUseful: Bool {
        status == .useful && !elements.isEmpty
    }

    fileprivate static func failure(
        _ status: AccessibilitySnapshotStatus,
        target: AccessibilitySnapshotTarget,
        elapsedMilliseconds: Double,
        wasTruncated: Bool = false
    ) -> Self {
        Self(
            status: status,
            target: target,
            elements: [],
            nodesVisited: 0,
            wasTruncated: wasTruncated,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }
}

public struct BoundedAccessibilitySnapshotProjector: Sendable {
    public static let supportedRoles: Set<String> = [
        "AXButton", "AXCell", "AXCheckBox", "AXComboBox", "AXDocument", "AXHeading",
        "AXImage", "AXLink", "AXMenuButton", "AXMenuItem", "AXPopUpButton", "AXRadioButton",
        "AXRow", "AXSecureTextField", "AXStaticText", "AXTab", "AXTextArea", "AXTextField",
        "AXWebArea",
    ]

    public let limits: AccessibilitySnapshotLimits

    public init(limits: AccessibilitySnapshotLimits = AccessibilitySnapshotLimits()) {
        self.limits = limits
    }

    public func project(
        root: any AccessibilitySnapshotNode,
        target: AccessibilitySnapshotTarget,
        observedWindow: AccessibilityObservedWindow,
        nowNanoseconds: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> AccessibilitySnapshot {
        let started = nowNanoseconds()
        guard Self.matches(target: target, observed: observedWindow) else {
            return .failure(
                .targetMismatch,
                target: target,
                elapsedMilliseconds: elapsedMilliseconds(since: started, now: nowNanoseconds())
            )
        }

        var stack: [(node: any AccessibilitySnapshotNode, depth: Int, path: [Int])] = [
            (root, 0, [])
        ]
        var elements: [ProjectedAccessibilityElement] = []
        var nodesVisited = 0
        var wasTruncated = false

        while let item = stack.popLast() {
            let current = nowNanoseconds()
            guard current &- started < limits.timeBudgetNanoseconds else {
                return .failure(
                    .timedOut,
                    target: target,
                    elapsedMilliseconds: elapsedMilliseconds(since: started, now: current),
                    wasTruncated: true
                )
            }
            guard nodesVisited < limits.maximumNodes else {
                wasTruncated = true
                break
            }
            nodesVisited += 1

            let role = item.node.role
            let subrole = item.node.subrole
            if Self.supportedRoles.contains(role) {
                let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
                let title = truncated(item.node.title)
                let value = secure ? nil : truncated(item.node.value)
                let nodeDescription = truncated(item.node.nodeDescription)
                let help = truncated(item.node.help)
                let identifier = truncated(item.node.identifier)
                let hasProjectedText = [title, value, nodeDescription, help]
                    .compactMap { $0 }
                    .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if hasProjectedText {
                    elements.append(
                        ProjectedAccessibilityElement(
                            role: role,
                            subrole: truncated(subrole),
                            title: title,
                            value: value,
                            nodeDescription: nodeDescription,
                            help: help,
                            identifier: identifier,
                            bounds: item.node.bounds,
                            isEnabled: item.node.isEnabled,
                            isFocused: item.node.isFocused,
                            hierarchyPath: item.path,
                            signature: Self.signature(
                                role: role,
                                subrole: subrole,
                                identifier: identifier,
                                path: item.path
                            )
                        )
                    )
                }
            }

            let remainingNodeCapacity = max(0, limits.maximumNodes - nodesVisited)
            if item.depth < limits.maximumDepth {
                let childBatch = item.node.children(maximumCount: remainingNodeCapacity)
                if childBatch.wasTruncated {
                    wasTruncated = true
                }
                for (index, child) in childBatch.nodes.enumerated().reversed() {
                    stack.append((child, item.depth + 1, item.path + [index]))
                }
            } else if !item.node.children(maximumCount: 1).nodes.isEmpty {
                wasTruncated = true
            }
        }

        if !stack.isEmpty {
            wasTruncated = true
        }
        let elapsed = elapsedMilliseconds(since: started, now: nowNanoseconds())
        return AccessibilitySnapshot(
            status: elements.isEmpty ? .empty : .useful,
            target: target,
            elements: elements,
            nodesVisited: nodesVisited,
            wasTruncated: wasTruncated,
            elapsedMilliseconds: elapsed
        )
    }

    private func truncated(_ value: String?) -> String? {
        value.map { String($0.prefix(limits.maximumStringLength)) }
    }

    private static func matches(
        target: AccessibilitySnapshotTarget,
        observed: AccessibilityObservedWindow
    ) -> Bool {
        target.processID == observed.processID
            && target.title == observed.title
            && abs(target.bounds.x - observed.bounds.x) <= 1
            && abs(target.bounds.y - observed.bounds.y) <= 1
            && abs(target.bounds.width - observed.bounds.width) <= 1
            && abs(target.bounds.height - observed.bounds.height) <= 1
    }

    private static func signature(
        role: String,
        subrole: String?,
        identifier: String?,
        path: [Int]
    ) -> String {
        let pathValue = path.map(String.init).joined(separator: ".")
        return [role, subrole ?? "", identifier ?? "", pathValue].joined(separator: "|")
    }
}

public struct SystemAccessibilitySnapshotExtractor: Sendable {
    public let limits: AccessibilitySnapshotLimits

    public init(limits: AccessibilitySnapshotLimits = AccessibilitySnapshotLimits()) {
        self.limits = limits
    }

    public func snapshot(for target: AccessibilitySnapshotTarget) async -> AccessibilitySnapshot {
        let box = AccessibilitySnapshotContinuationBox()
        let started = DispatchTime.now().uptimeNanoseconds
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = autoreleasepool {
                    snapshotSynchronously(target: target, limits: limits, started: started)
                }
                box.finish(result)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + limits.timeBudgetMilliseconds / 1_000
            ) {
                box.finish(
                    .failure(
                        .timedOut,
                        target: target,
                        elapsedMilliseconds: elapsedMilliseconds(
                            since: started,
                            now: DispatchTime.now().uptimeNanoseconds
                        ),
                        wasTruncated: true
                    )
                )
            }
        }
    }
}

private final class AccessibilitySnapshotContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AccessibilitySnapshot, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<AccessibilitySnapshot, Never>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func finish(_ snapshot: AccessibilitySnapshot) {
        let continuation: CheckedContinuation<AccessibilitySnapshot, Never>? = lock.withLock {
            guard !finished else {
                return nil
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: snapshot)
    }
}

private final class SystemAccessibilitySnapshotNode: AccessibilitySnapshotNode {
    private let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    var role: String { attribute(kAXRoleAttribute) ?? "AXUnknown" }
    var subrole: String? { attribute(kAXSubroleAttribute) }
    var title: String? { attribute(kAXTitleAttribute) }
    var value: String? { attribute(kAXValueAttribute) }
    var nodeDescription: String? { attribute(kAXDescriptionAttribute) }
    var help: String? { attribute(kAXHelpAttribute) }
    var identifier: String? { attribute(kAXIdentifierAttribute) }
    var bounds: PointRect? { accessibilityBounds(element) }
    var isEnabled: Bool? { attribute(kAXEnabledAttribute) }
    var isFocused: Bool? { attribute(kAXFocusedAttribute) }
    func children(maximumCount: Int) -> (
        nodes: [any AccessibilitySnapshotNode], wasTruncated: Bool
    ) {
        guard maximumCount > 0 else {
            var childCount: CFIndex = 0
            let status = AXUIElementGetAttributeValueCount(
                element,
                kAXChildrenAttribute as CFString,
                &childCount
            )
            return ([], status == .success && childCount > 0)
        }
        var childCount: CFIndex = 0
        guard
            AXUIElementGetAttributeValueCount(
                element,
                kAXChildrenAttribute as CFString,
                &childCount
            ) == .success, childCount > 0
        else {
            return ([], false)
        }
        let requestedCount = min(childCount, CFIndex(maximumCount))
        var values: CFArray?
        guard
            AXUIElementCopyAttributeValues(
                element,
                kAXChildrenAttribute as CFString,
                0,
                requestedCount,
                &values
            ) == .success, let children = values as? [AXUIElement]
        else {
            return ([], childCount > 0)
        }
        return (
            children.map(SystemAccessibilitySnapshotNode.init),
            childCount > requestedCount
        )
    }

    private func attribute<T>(_ name: String) -> T? {
        accessibilityAttribute(element, name)
    }
}

private func snapshotSynchronously(
    target: AccessibilitySnapshotTarget,
    limits: AccessibilitySnapshotLimits,
    started: UInt64
) -> AccessibilitySnapshot {
    guard AXIsProcessTrusted() else {
        return .failure(
            .permissionDenied,
            target: target,
            elapsedMilliseconds: elapsedMilliseconds(
                since: started,
                now: DispatchTime.now().uptimeNanoseconds
            )
        )
    }

    let application = AXUIElementCreateApplication(pid_t(target.processID))
    AXUIElementSetMessagingTimeout(application, Float(limits.timeBudgetMilliseconds / 1_000))
    guard
        let focusedWindow: AXUIElement = accessibilityAttribute(
            application,
            kAXFocusedWindowAttribute
        ), let bounds = accessibilityBounds(focusedWindow)
    else {
        return .failure(
            .targetUnavailable,
            target: target,
            elapsedMilliseconds: elapsedMilliseconds(
                since: started,
                now: DispatchTime.now().uptimeNanoseconds
            )
        )
    }
    let observed = AccessibilityObservedWindow(
        processID: target.processID,
        bounds: bounds,
        title: accessibilityAttribute(focusedWindow, kAXTitleAttribute)
    )
    return BoundedAccessibilitySnapshotProjector(limits: limits).project(
        root: SystemAccessibilitySnapshotNode(focusedWindow),
        target: target,
        observedWindow: observed
    )
}

private func accessibilityBounds(_ element: AXUIElement) -> PointRect? {
    guard let positionValue: AXValue = accessibilityAttribute(element, kAXPositionAttribute),
        let sizeValue: AXValue = accessibilityAttribute(element, kAXSizeAttribute)
    else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &position),
        AXValueGetValue(sizeValue, .cgSize, &size)
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

private func accessibilityAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

private func elapsedMilliseconds(since started: UInt64, now: UInt64) -> Double {
    Double(now &- started) / 1_000_000
}
