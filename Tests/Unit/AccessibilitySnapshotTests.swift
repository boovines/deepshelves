import Foundation
import MemoryCapture
import MemoryEnrichment
import XCTest

final class AccessibilitySnapshotTests: XCTestCase {
    func testExactAcceptedWindowProjectsOnlySupportedRolesAndNeverSecureValues() throws {
        let secret = "LM029_SECURE_VALUE_SENTINEL"
        let unsupported = "LM029_UNSUPPORTED_ROLE_SENTINEL"
        let target = fixtureTarget()
        let root = FixtureAccessibilityNode(
            role: "AXWindow",
            title: "Approved Window",
            children: [
                FixtureAccessibilityNode(
                    role: "AXStaticText",
                    title: "Visible status",
                    bounds: PointRect(x: 120, y: 100, width: 200, height: 20)
                ),
                FixtureAccessibilityNode(
                    role: "AXButton",
                    title: "Continue",
                    description: "Advance workflow"
                ),
                FixtureAccessibilityNode(role: "AXGroup", title: unsupported),
                FixtureAccessibilityNode(
                    role: "AXSecureTextField",
                    title: "Password",
                    value: secret
                ),
            ]
        )

        let snapshot = BoundedAccessibilitySnapshotProjector().project(
            root: root,
            target: target,
            observedWindow: fixtureObservedWindow()
        )

        XCTAssertEqual(snapshot.status, .useful)
        XCTAssertEqual(snapshot.target, target)
        XCTAssertEqual(snapshot.nodesVisited, 5)
        XCTAssertTrue(snapshot.elements.contains { $0.title == "Visible status" })
        XCTAssertTrue(snapshot.elements.contains { $0.title == "Continue" })
        XCTAssertTrue(snapshot.elements.contains { $0.title == "Password" && $0.value == nil })
        XCTAssertFalse(snapshot.elements.contains { $0.title == unsupported })
        XCTAssertFalse(snapshot.elements.contains { $0.value == secret })
        XCTAssertEqual(snapshot.elements.map(\.hierarchyPath), [[0], [1], [3]])
    }

    func testPIDBoundsAndTitleMustAllMatchAcceptedForegroundWindow() throws {
        let target = fixtureTarget()
        let sentinel = "LM029_BACKGROUND_WINDOW_SENTINEL"
        let root = FixtureAccessibilityNode(
            role: "AXWindow",
            children: [FixtureAccessibilityNode(role: "AXStaticText", title: sentinel)]
        )
        let mismatches = [
            AccessibilityObservedWindow(
                processID: target.processID + 1,
                bounds: target.bounds,
                title: target.title
            ),
            AccessibilityObservedWindow(
                processID: target.processID,
                bounds: PointRect(x: 900, y: 900, width: 100, height: 100),
                title: target.title
            ),
            AccessibilityObservedWindow(
                processID: target.processID,
                bounds: target.bounds,
                title: "Background Window"
            ),
        ]

        for mismatch in mismatches {
            let snapshot = BoundedAccessibilitySnapshotProjector().project(
                root: root,
                target: target,
                observedWindow: mismatch
            )
            XCTAssertEqual(snapshot.status, .targetMismatch)
            XCTAssertEqual(snapshot.nodesVisited, 0)
            XCTAssertTrue(snapshot.elements.isEmpty)
            XCTAssertFalse(String(describing: snapshot).contains(sentinel))
        }
    }

    func testNodeDepthStringAndTimeBudgetsFailClosedOrTruncateDeterministically() throws {
        let target = fixtureTarget()
        let deep = FixtureAccessibilityNode(
            role: "AXGroup",
            children: [
                FixtureAccessibilityNode(
                    role: "AXStaticText",
                    title: String(repeating: "x", count: 80),
                    children: [FixtureAccessibilityNode(role: "AXStaticText", title: "too deep")]
                )
            ]
        )
        let wide = FixtureAccessibilityNode(
            role: "AXWindow",
            children: [deep]
                + (0..<20).map {
                    FixtureAccessibilityNode(role: "AXStaticText", title: "row-\($0)")
                }
        )
        let limits = AccessibilitySnapshotLimits(
            maximumNodes: 6,
            maximumDepth: 2,
            maximumStringLength: 16,
            timeBudgetMilliseconds: 45
        )
        let bounded = BoundedAccessibilitySnapshotProjector(limits: limits).project(
            root: wide,
            target: target,
            observedWindow: fixtureObservedWindow()
        )

        XCTAssertEqual(bounded.status, .useful)
        XCTAssertLessThanOrEqual(bounded.nodesVisited, 6)
        XCTAssertTrue(bounded.wasTruncated)
        XCTAssertTrue(
            bounded.elements.allSatisfy { element in
                [element.title, element.value, element.nodeDescription, element.help]
                    .compactMap { $0 }
                    .allSatisfy { $0.count <= 16 }
            })

        var tick: UInt64 = 0
        let timedOut = BoundedAccessibilitySnapshotProjector(
            limits: AccessibilitySnapshotLimits(timeBudgetMilliseconds: 2)
        ).project(
            root: wide,
            target: target,
            observedWindow: fixtureObservedWindow(),
            nowNanoseconds: {
                defer { tick += 1_000_000 }
                return tick
            }
        )
        XCTAssertEqual(timedOut.status, .timedOut)
        XCTAssertTrue(timedOut.elements.isEmpty)
        XCTAssertTrue(timedOut.wasTruncated)
    }

    func testProjectionDoesNotRetainRawAccessibilityTree() throws {
        weak var releasedRoot: FixtureAccessibilityNode?
        var root: FixtureAccessibilityNode? = FixtureAccessibilityNode(
            role: "AXWindow",
            children: [FixtureAccessibilityNode(role: "AXStaticText", title: "Ephemeral")]
        )
        releasedRoot = root

        let snapshot = BoundedAccessibilitySnapshotProjector().project(
            root: try XCTUnwrap(root),
            target: fixtureTarget(),
            observedWindow: fixtureObservedWindow()
        )
        root = nil

        XCTAssertEqual(snapshot.status, .useful)
        XCTAssertNil(releasedRoot)
    }

    func testCanonical250FixtureCoverageAndLatencyGatesPass() throws {
        let fixtures = S2FixtureCatalog.make(seed: 0xD335_5EED).axFixtures
        let projector = BoundedAccessibilitySnapshotProjector()
        let target = fixtureTarget()
        var useful = 0
        var latencies: [Double] = []

        for fixture in fixtures {
            let root = FixtureAccessibilityNode(fixture.root)
            let started = ContinuousClock.now
            let snapshot = projector.project(
                root: root,
                target: target,
                observedWindow: fixtureObservedWindow()
            )
            latencies.append(started.duration(to: .now).milliseconds)
            if snapshot.status == .useful {
                useful += 1
            }
        }

        let coverage = Double(useful) / Double(fixtures.count)
        let sorted = latencies.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(
            "LM029_METRIC fixtures=\(fixtures.count) useful=\(useful) "
                + "coverage=\(coverage) p95_ms=\(p95)"
        )
        XCTAssertGreaterThanOrEqual(coverage, 0.80)
        XCTAssertLessThan(p95, 50)
    }

    private func fixtureTarget() -> AccessibilitySnapshotTarget {
        AccessibilitySnapshotTarget(
            captureEpochID: UUID(uuidString: "29000000-0000-0000-0000-000000000029")!,
            windowID: 29,
            processID: 42,
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            title: "Approved Window"
        )
    }

    private func fixtureObservedWindow() -> AccessibilityObservedWindow {
        let target = fixtureTarget()
        return AccessibilityObservedWindow(
            processID: target.processID,
            bounds: target.bounds,
            title: target.title
        )
    }
}

private final class FixtureAccessibilityNode: AccessibilitySnapshotNode {
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let nodeDescription: String?
    let help: String?
    let identifier: String?
    let bounds: PointRect?
    let isEnabled: Bool?
    let isFocused: Bool?
    private let childNodes: [any AccessibilitySnapshotNode]

    init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        help: String? = nil,
        identifier: String? = nil,
        bounds: PointRect? = nil,
        isEnabled: Bool? = nil,
        isFocused: Bool? = nil,
        children: [any AccessibilitySnapshotNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        nodeDescription = description
        self.help = help
        self.identifier = identifier
        self.bounds = bounds
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        childNodes = children
    }

    func children(maximumCount: Int) -> (
        nodes: [any AccessibilitySnapshotNode], wasTruncated: Bool
    ) {
        let nodes = Array(childNodes.prefix(max(0, maximumCount)))
        return (nodes, nodes.count < childNodes.count)
    }

    convenience init(_ node: AXFixtureNode) {
        self.init(
            role: node.role,
            subrole: node.subrole,
            title: node.title,
            value: node.value,
            description: node.description,
            help: node.help,
            identifier: node.identifier,
            bounds: node.frame.map {
                PointRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            isEnabled: node.isEnabled,
            isFocused: node.isFocused,
            children: node.children.map(FixtureAccessibilityNode.init)
        )
    }
}

extension Duration {
    fileprivate var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
