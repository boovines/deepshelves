import AppKit
import Foundation
import MemoryCapture
import XCTest

final class ForegroundWindowResolverTests: XCTestCase {
    func testFiveHundredTransitionFixtureResolvesExactlyOrEmitsZeroPixelTypedGap() throws {
        let configuration = try loadFixtureConfiguration()
        let transitions = LM020WindowTransitionFixture.make(seed: configuration.seed)

        XCTAssertEqual(transitions.count, configuration.transitionCount)
        var approvedCount = 0
        var gapCounts: [String: Int] = [:]
        for transition in transitions {
            let result = WindowResolver.resolve(
                focused: transition.focused,
                candidates: transition.candidates
            )
            XCTAssertEqual(result, transition.expectedResolution, transition.id)
            switch result {
            case let .approved(window):
                approvedCount += 1
                XCTAssertEqual(window.windowID, transition.expectedWindowID, transition.id)
            case let .gap(reason):
                gapCounts[reason.rawValue, default: 0] += 1
                XCTAssertNil(transition.pixelPayload, transition.id)
            }
        }

        XCTAssertEqual(approvedCount, configuration.approvedCount)
        XCTAssertEqual(gapCounts, configuration.gapCounts)
    }

    func testResolverRequiresAXIdentityAndTopLevelGeometryToAgree() throws {
        let candidate = ShareableWindowDescriptor.fixture(windowID: 91)
        let wrongRole = FocusedWindowDescriptor.fixture(role: "AXButton")
        let mismatchedTopLevel = FocusedWindowDescriptor.fixture(
            topLevelBounds: PointRect(x: 1_000, y: 800, width: 200, height: 100)
        )
        let unconfirmedTopLevel = FocusedWindowDescriptor.fixture(
            hasConfirmedAXIdentity: false
        )

        XCTAssertEqual(
            WindowResolver.resolve(focused: wrongRole, candidates: [candidate]),
            .gap(.unresolvedWindow)
        )
        XCTAssertEqual(
            WindowResolver.resolve(focused: mismatchedTopLevel, candidates: [candidate]),
            .gap(.unresolvedWindow)
        )
        XCTAssertEqual(
            WindowResolver.resolve(focused: unconfirmedTopLevel, candidates: [candidate]),
            .gap(.unresolvedWindow)
        )
    }

    func testForegroundResolverRefreshesOncePerTransitionAndAgainAfterDisappearance() async throws {
        let snapshot = ForegroundWindowSnapshot.available(
            application: ForegroundApplicationIdentity(
                processID: 42,
                bundleIdentifier: "com.example.fixture",
                localizedName: "Fixture"
            ),
            window: .fixture()
        )
        let reader = FakeForegroundWindowSnapshotReader(snapshot: snapshot)
        let target = ForegroundWindowCaptureTarget.fixture(
            windowID: 91,
            processID: 42,
            displayID: 1,
            width: 900,
            height: 640,
            title: "Quarterly Plan",
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640)
        )
        let refresher = FakeShareableWindowRefresher(targets: [target])
        let resolver = ForegroundCaptureTargetResolver(
            snapshotReader: reader,
            refresher: refresher
        )

        let first = await resolver.resolve(transitionSequence: 1)
        let cached = await resolver.resolve(transitionSequence: 1)
        await resolver.noteTargetDisappeared(windowID: 91)
        let recovered = await resolver.resolve(transitionSequence: 1)

        XCTAssertEqual(first.target?.windowID, 91)
        XCTAssertEqual(cached.target?.windowID, 91)
        XCTAssertEqual(recovered.target?.windowID, 91)
        XCTAssertEqual(first.pixelPayloadCount, 0)
        let refreshCount = await refresher.refreshCount
        let readCount = await reader.readCount
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(readCount, 2)
    }

    func testForegroundResolverNeverExposesTargetForEveryGapType() async throws {
        for (index, transition) in LM020WindowTransitionFixture.make(seed: 1279938620)
            .filter({ if case .gap = $0.expectedResolution { true } else { false } })
            .prefix(150)
            .enumerated()
        {
            let snapshot: ForegroundWindowSnapshot
            if let focused = transition.focused {
                snapshot = .available(
                    application: ForegroundApplicationIdentity(
                        processID: focused.processID,
                        bundleIdentifier: "com.example.fixture",
                        localizedName: "Fixture"
                    ),
                    window: focused
                )
            } else {
                snapshot = .gap(.noWindow)
            }
            let reader = FakeForegroundWindowSnapshotReader(snapshot: snapshot)
            let refresher = FakeShareableWindowRefresher(
                targets: transition.candidates.map(ForegroundWindowCaptureTarget.fixture)
            )
            let resolver = ForegroundCaptureTargetResolver(
                snapshotReader: reader,
                refresher: refresher
            )

            let result = await resolver.resolve(transitionSequence: UInt64(index + 1))

            XCTAssertNil(result.target, transition.id)
            XCTAssertEqual(result.pixelPayloadCount, 0, transition.id)
            guard case .gap = result.resolution else {
                return XCTFail("Expected a typed gap for \(transition.id)")
            }
        }
    }

    func testWorkspaceMonitorEmitsSequencedForegroundApplicationTransitions() async throws {
        let monitor = NSWorkspaceForegroundApplicationMonitor()
        var iterator = monitor.transitions().makeAsyncIterator()

        let initialValue = await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        let activationValue = await iterator.next()
        let activation = try XCTUnwrap(activationValue)

        XCTAssertEqual(initial, ForegroundApplicationTransition(sequence: 0, kind: .initial))
        XCTAssertEqual(
            activation,
            ForegroundApplicationTransition(sequence: 1, kind: .applicationActivated)
        )
    }

    private func loadFixtureConfiguration() throws -> LM020FixtureConfiguration {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM020/window-transition-corpus.json")
        return try JSONDecoder().decode(
            LM020FixtureConfiguration.self,
            from: Data(contentsOf: sourceURL)
        )
    }
}

private struct LM020FixtureConfiguration: Decodable {
    let seed: UInt64
    let transitionCount: Int
    let approvedCount: Int
    let gapCounts: [String: Int]
}

private actor FakeForegroundWindowSnapshotReader: ForegroundWindowSnapshotReading {
    let snapshot: ForegroundWindowSnapshot
    private(set) var readCount = 0

    init(snapshot: ForegroundWindowSnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot() async -> ForegroundWindowSnapshot {
        readCount += 1
        return snapshot
    }
}

private actor FakeShareableWindowRefresher: ShareableWindowRefreshing {
    let targets: [ForegroundWindowCaptureTarget]
    private(set) var refreshCount = 0

    init(targets: [ForegroundWindowCaptureTarget]) {
        self.targets = targets
    }

    func refresh() async -> ShareableWindowRefreshResult {
        refreshCount += 1
        return ShareableWindowRefreshResult(status: .available, targets: targets)
    }
}

private extension FocusedWindowDescriptor {
    static func fixture(
        role: String = "AXWindow",
        topLevelBounds: PointRect? = PointRect(x: 100, y: 80, width: 900, height: 640),
        hasConfirmedAXIdentity: Bool = true
    ) -> Self {
        Self(
            processID: 42,
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            title: "Quarterly Plan",
            isMinimized: false,
            role: role,
            subrole: "AXStandardWindow",
            topLevelBounds: topLevelBounds,
            hasConfirmedAXIdentity: hasConfirmedAXIdentity
        )
    }
}

private extension ShareableWindowDescriptor {
    static func fixture(windowID: UInt32) -> Self {
        Self(
            windowID: windowID,
            processID: 42,
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            title: "Quarterly Plan",
            isOnScreen: true,
            isNormalContent: true,
            intersectsMainDisplay: true
        )
    }
}
