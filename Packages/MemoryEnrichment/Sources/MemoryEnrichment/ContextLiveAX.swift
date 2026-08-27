import ApplicationServices
import Foundation

public enum LiveAXProbeStatus: String, Codable, Sendable {
    case useful
    case empty
    case timedOut
    case permissionDenied
    case targetUnavailable
}

public struct LiveAXProbeResult: Codable, Sendable {
    public let status: LiveAXProbeStatus
    public let elapsedMilliseconds: Double
    public let nodesVisited: Int
    public let spanCount: Int
    public let targetAssociated: Bool
    public let truncated: Bool

    public init(
        status: LiveAXProbeStatus,
        elapsedMilliseconds: Double,
        nodesVisited: Int,
        spanCount: Int,
        targetAssociated: Bool,
        truncated: Bool
    ) {
        self.status = status
        self.elapsedMilliseconds = elapsedMilliseconds
        self.nodesVisited = nodesVisited
        self.spanCount = spanCount
        self.targetAssociated = targetAssociated
        self.truncated = truncated
    }
}

private final class LiveAXContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<LiveAXProbeResult, Never>?

    func install(_ continuation: CheckedContinuation<LiveAXProbeResult, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: LiveAXProbeResult) {
        lock.lock()
        guard !resumed, let continuation else {
            lock.unlock()
            return
        }
        resumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }
}

public struct LiveAXProbe: Sendable {
    public let limits: AXTraversalLimits
    public let timeoutMilliseconds: Double

    public init(
        limits: AXTraversalLimits = AXTraversalLimits(maximumNodes: 256, maximumDepth: 12),
        timeoutMilliseconds: Double = 45
    ) {
        self.limits = limits
        self.timeoutMilliseconds = max(1, timeoutMilliseconds)
    }

    public func inspect(processID: pid_t, expectedWindowTitle: String) async -> LiveAXProbeResult {
        let box = LiveAXContinuationBox()
        let started = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = inspectSynchronously(
                    processID: processID,
                    expectedWindowTitle: expectedWindowTitle,
                    limits: limits,
                    timeoutSeconds: timeoutMilliseconds / 1_000,
                    started: started
                )
                box.finish(result)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeoutMilliseconds / 1_000
            ) {
                box.finish(
                    LiveAXProbeResult(
                        status: .timedOut,
                        elapsedMilliseconds: started.duration(to: .now).milliseconds,
                        nodesVisited: 0,
                        spanCount: 0,
                        targetAssociated: false,
                        truncated: true
                    )
                )
            }
        }
    }
}

private func inspectSynchronously(
    processID: pid_t,
    expectedWindowTitle: String,
    limits: AXTraversalLimits,
    timeoutSeconds: Double,
    started: ContinuousClock.Instant
) -> LiveAXProbeResult {
    guard AXIsProcessTrusted() else {
        return probeResult(.permissionDenied, started: started)
    }
    let application = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(application, Float(timeoutSeconds))
    guard let windows: [AXUIElement] = axAttribute(application, kAXWindowsAttribute),
          let window = windows.first(where: { element in
              let title: String? = axAttribute(element, kAXTitleAttribute)
              return title == expectedWindowTitle
          })
    else {
        return probeResult(.targetUnavailable, started: started)
    }

    var remaining = limits.maximumNodes
    var truncated = false
    let root = copyNode(window, depth: 0, remaining: &remaining, limits: limits, truncated: &truncated)
    let projection = BoundedAXProjector(limits: limits).project(root)
    return LiveAXProbeResult(
        status: projection.isUseful ? .useful : .empty,
        elapsedMilliseconds: started.duration(to: .now).milliseconds,
        nodesVisited: projection.nodesVisited,
        spanCount: projection.spans.count,
        targetAssociated: true,
        truncated: truncated || projection.wasTruncated
    )
}

private func copyNode(
    _ element: AXUIElement,
    depth: Int,
    remaining: inout Int,
    limits: AXTraversalLimits,
    truncated: inout Bool
) -> AXFixtureNode {
    guard remaining > 0 else {
        truncated = true
        return AXFixtureNode(role: "AXUnknown")
    }
    remaining -= 1
    let role: String = axAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
    let subrole: String? = axAttribute(element, kAXSubroleAttribute)
    let title: String? = axAttribute(element, kAXTitleAttribute)
    let isSecure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
    let value: String? = isSecure ? nil : axAttribute(element, kAXValueAttribute)
    let description: String? = axAttribute(element, kAXDescriptionAttribute)
    let help: String? = axAttribute(element, kAXHelpAttribute)
    let identifier: String? = axAttribute(element, kAXIdentifierAttribute)
    let enabled: Bool? = axAttribute(element, kAXEnabledAttribute)
    let focused: Bool? = axAttribute(element, kAXFocusedAttribute)
    let frame = axFrame(element)
    var projectedChildren: [AXFixtureNode] = []
    if depth < limits.maximumDepth, let children: [AXUIElement] = axAttribute(element, kAXChildrenAttribute) {
        for child in children {
            guard remaining > 0 else {
                truncated = true
                break
            }
            projectedChildren.append(
                copyNode(child, depth: depth + 1, remaining: &remaining, limits: limits, truncated: &truncated)
            )
        }
    } else if depth >= limits.maximumDepth {
        truncated = true
    }
    return AXFixtureNode(
        role: role,
        subrole: subrole,
        title: title,
        value: value,
        description: description,
        help: help,
        identifier: identifier,
        frame: frame,
        isEnabled: enabled,
        isFocused: focused,
        children: projectedChildren
    )
}

private func axFrame(_ element: AXUIElement) -> ContextRect? {
    guard let positionValue: AXValue = axAttribute(element, kAXPositionAttribute),
          let sizeValue: AXValue = axAttribute(element, kAXSizeAttribute)
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
    return ContextRect(
        x: position.x,
        y: position.y,
        width: size.width,
        height: size.height
    )
}

private func axAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

private func probeResult(
    _ status: LiveAXProbeStatus,
    started: ContinuousClock.Instant
) -> LiveAXProbeResult {
    LiveAXProbeResult(
        status: status,
        elapsedMilliseconds: started.duration(to: .now).milliseconds,
        nodesVisited: 0,
        spanCount: 0,
        targetAssociated: false,
        truncated: false
    )
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
