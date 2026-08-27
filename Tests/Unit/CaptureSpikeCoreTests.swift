import MemoryCapture
import XCTest

final class CaptureSpikeCoreTests: XCTestCase {
    func testResolverApprovesOnlyTheFocusedProcessesMatchingWindow() throws {
        let focused = FocusedWindowDescriptor(
            processID: 42,
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            title: "Quarterly Plan",
            isMinimized: false
        )
        let candidates = [
            ShareableWindowDescriptor(
                windowID: 7,
                processID: 99,
                bounds: focused.bounds,
                title: focused.title,
                isOnScreen: true,
                isNormalContent: true,
                intersectsMainDisplay: true
            ),
            ShareableWindowDescriptor(
                windowID: 8,
                processID: 42,
                bounds: focused.bounds,
                title: focused.title,
                isOnScreen: true,
                isNormalContent: true,
                intersectsMainDisplay: true
            ),
        ]

        let resolution = WindowResolver.resolve(focused: focused, candidates: candidates)
        XCTAssertEqual(resolution, .approved(candidates[1]))
    }

    func testResolverFailsClosedWhenGeometryAndTitleCannotDisambiguate() throws {
        let focused = FocusedWindowDescriptor(
            processID: 42,
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            title: "Quarterly Plan",
            isMinimized: false
        )
        let duplicate = ShareableWindowDescriptor(
            windowID: 8,
            processID: 42,
            bounds: focused.bounds,
            title: focused.title,
            isOnScreen: true,
            isNormalContent: true,
            intersectsMainDisplay: true
        )

        let resolution = WindowResolver.resolve(
            focused: focused,
            candidates: [duplicate, duplicate.with(windowID: 9)]
        )

        XCTAssertEqual(resolution, .gap(.ambiguousWindow))
    }

    func testResolverFiltersIneligibleCandidatesAndUsesNormalizedTitleTieBreaker() throws {
        let focused = FocusedWindowDescriptor(
            processID: 42,
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            title: "  Quarterly   Plan ",
            isMinimized: false
        )
        let wrongTitle = ShareableWindowDescriptor(
            windowID: 8,
            processID: 42,
            bounds: PointRect(x: 102, y: 81, width: 899, height: 641),
            title: "Other Document",
            isOnScreen: true,
            isNormalContent: true,
            intersectsMainDisplay: true
        )
        let expected = wrongTitle.with(windowID: 9, title: "quarterly plan")
        let ineligible = wrongTitle.with(windowID: 10, title: focused.title, isOnScreen: false)

        let resolution = WindowResolver.resolve(
            focused: focused,
            candidates: [wrongTitle, expected, ineligible]
        )

        XCTAssertEqual(resolution, .approved(expected))
    }

    func testResolverEmitsTypedMetadataOnlyGapsForIneligibleSurfaces() throws {
        let focused = FocusedWindowDescriptor(
            processID: 42,
            bounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            title: "Quarterly Plan",
            isMinimized: false
        )
        let eligible = ShareableWindowDescriptor(
            windowID: 8,
            processID: 42,
            bounds: focused.bounds,
            title: focused.title,
            isOnScreen: true,
            isNormalContent: true,
            intersectsMainDisplay: true
        )

        XCTAssertEqual(WindowResolver.resolve(focused: focused, candidates: []), .gap(.noWindow))
        XCTAssertEqual(
            WindowResolver.resolve(
                focused: focused.with(isMinimized: true),
                candidates: [eligible]
            ),
            .gap(.minimizedWindow)
        )
        XCTAssertEqual(
            WindowResolver.resolve(
                focused: focused,
                candidates: [eligible.with(windowID: 9, intersectsMainDisplay: false)]
            ),
            .gap(.unsupportedDisplay)
        )
        XCTAssertEqual(
            WindowResolver.resolve(
                focused: focused,
                candidates: [eligible.with(windowID: 10, isNormalContent: false)]
            ),
            .gap(.protectedSurface)
        )
    }

    func testEpochAdmissionRejectsStaleAndMismatchedBuffers() throws {
        let epochID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let epoch = WindowCaptureEpoch(
            id: epochID,
            targetWindowID: 8,
            processID: 42,
            encodedSize: PixelSize(width: 1_920, height: 1_080),
            filterAppliedNanoseconds: 1_000
        )
        let current = FrameCandidate(
            epochID: epochID,
            targetWindowID: 8,
            focusedWindowID: 8,
            dimensions: epoch.encodedSize,
            deliveredNanoseconds: 1_001,
            policyApproved: true
        )

        XCTAssertEqual(
            FrameAdmission.evaluate(current.with(deliveredNanoseconds: 999), against: epoch),
            .rejected(.beforeFilterApplied)
        )
        XCTAssertEqual(
            FrameAdmission.evaluate(current.with(targetWindowID: 7), against: epoch),
            .rejected(.targetMismatch)
        )
        XCTAssertEqual(FrameAdmission.evaluate(current, against: epoch), .accepted)
    }

    func testAcceptanceGatePinsActiveStaticIndexAndIdleCadence() throws {
        let epochID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var gate = FrameAcceptanceGate()

        XCTAssertEqual(
            gate.evaluate(epochID: epochID, timestampNanoseconds: 0, signature: 1, lastActivityNanoseconds: 0),
            .accepted(index: true, reason: .firstEpochFrame)
        )
        XCTAssertEqual(
            gate.evaluate(epochID: epochID, timestampNanoseconds: 500_000_000, signature: 2, lastActivityNanoseconds: 0),
            .rejected(.activeRateLimit)
        )
        XCTAssertEqual(
            gate.evaluate(epochID: epochID, timestampNanoseconds: 1_000_000_000, signature: 2, lastActivityNanoseconds: 0),
            .accepted(index: false, reason: .visualChange)
        )
        XCTAssertEqual(
            gate.evaluate(epochID: epochID, timestampNanoseconds: 2_000_000_000, signature: 2, lastActivityNanoseconds: 0),
            .rejected(.staticDuplicate)
        )
        XCTAssertEqual(
            gate.evaluate(epochID: epochID, timestampNanoseconds: 31_000_000_000, signature: 2, lastActivityNanoseconds: 0),
            .accepted(index: true, reason: .staticHeartbeat)
        )
        XCTAssertEqual(
            gate.evaluate(epochID: epochID, timestampNanoseconds: 301_000_000_000, signature: 3, lastActivityNanoseconds: 0),
            .rejected(.idleSuspended)
        )
    }

    func testMediaChunkScopePermitsOnlyOneEpochTargetDimensionAndThirtySeconds() throws {
        let epochID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let scope = MediaChunkScope(
            epochID: epochID,
            targetWindowID: 8,
            dimensions: PixelSize(width: 1_920, height: 1_080),
            startedNanoseconds: 1_000
        )
        let frame = FrameCandidate(
            epochID: epochID,
            targetWindowID: 8,
            focusedWindowID: 8,
            dimensions: scope.dimensions,
            deliveredNanoseconds: 2_000,
            policyApproved: true
        )

        XCTAssertEqual(scope.evaluate(frame), .appendAllowed)
        XCTAssertEqual(
            scope.evaluate(frame.with(epochID: UUID())),
            .closeBeforeAppend(.epochChanged)
        )
        XCTAssertEqual(
            scope.evaluate(frame.with(dimensions: PixelSize(width: 1_680, height: 945))),
            .closeBeforeAppend(.dimensionsChanged)
        )
        XCTAssertEqual(
            scope.evaluate(frame.with(deliveredNanoseconds: 30_000_001_001)),
            .closeBeforeAppend(.durationReached)
        )
    }

    func testCapabilityStatusRequiresScreenRecordingAndAccessibility() throws {
        XCTAssertEqual(
            CaptureCapabilityStatus(screenRecording: false, accessibility: false).missing,
            [.screenRecording, .accessibility]
        )
        XCTAssertFalse(CaptureCapabilityStatus(screenRecording: true, accessibility: false).isReady)
        XCTAssertTrue(CaptureCapabilityStatus(screenRecording: true, accessibility: true).isReady)
    }

    func testCaptureGeometryPreservesAspectAndProducesEvenHEVCDimensions() throws {
        XCTAssertEqual(
            CaptureGeometry.encodedSize(for: PointRect(x: 0, y: 0, width: 3_840, height: 2_160)),
            PixelSize(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            CaptureGeometry.encodedSize(for: PointRect(x: 0, y: 0, width: 913, height: 641)),
            PixelSize(width: 912, height: 640)
        )
    }

    func testHEVCProfileRequiresHardwareAndOneSecondFragments() throws {
        let profile = HEVCEncodingProfile.production

        XCTAssertEqual(profile.codecFourCC, "hvc1")
        XCTAssertTrue(profile.requiresHardwareAcceleration)
        XCTAssertEqual(profile.fragmentIntervalNanoseconds, 1_000_000_000)
        XCTAssertEqual(profile.keyFrameIntervalSeconds, 1)
        XCTAssertEqual(profile.averageBitRate, 2_000_000)
    }

    func testFocusPollingCadenceRetainsOneSecondTransitionMargin() throws {
        XCTAssertEqual(CaptureConstants.focusPollIntervalNanoseconds, 100_000_000)
        XCTAssertLessThan(CaptureConstants.focusPollIntervalNanoseconds, 1_000_000_000)
    }

    func testWriterRolloverLeavesOneReceiveIntervalBeforeMaximumDuration() throws {
        XCTAssertEqual(CaptureConstants.writerRolloverIntervalNanoseconds, 29_000_000_000)
        XCTAssertLessThan(
            CaptureConstants.writerRolloverIntervalNanoseconds,
            CaptureConstants.maximumChunkDurationNanoseconds
        )
    }

    func testRefreshLeaseSuppressesDuplicatesAndIgnoresLateCompletion() throws {
        var state = RefreshLeaseState()
        let first = try XCTUnwrap(
            state.begin(nowNanoseconds: 1_000, cooldownNanoseconds: 30_000)
        )
        XCTAssertNil(state.begin(nowNanoseconds: 2_000, cooldownNanoseconds: 30_000))
        let replacement = try XCTUnwrap(
            state.begin(nowNanoseconds: 31_001, cooldownNanoseconds: 30_000)
        )

        state.complete(first)
        XCTAssertNil(state.begin(nowNanoseconds: 31_002, cooldownNanoseconds: 30_000))
        state.complete(replacement)
        XCTAssertNotNil(state.begin(nowNanoseconds: 31_003, cooldownNanoseconds: 30_000))
    }
}

private extension FrameCandidate {
    func with(
        epochID: UUID? = nil,
        targetWindowID: UInt32? = nil,
        dimensions: PixelSize? = nil,
        deliveredNanoseconds: UInt64? = nil
    ) -> FrameCandidate {
        FrameCandidate(
            epochID: epochID ?? self.epochID,
            targetWindowID: targetWindowID ?? self.targetWindowID,
            focusedWindowID: focusedWindowID,
            dimensions: dimensions ?? self.dimensions,
            deliveredNanoseconds: deliveredNanoseconds ?? self.deliveredNanoseconds,
            policyApproved: policyApproved
        )
    }
}

private extension FocusedWindowDescriptor {
    func with(isMinimized: Bool) -> FocusedWindowDescriptor {
        FocusedWindowDescriptor(
            processID: processID,
            bounds: bounds,
            title: title,
            isMinimized: isMinimized
        )
    }
}

private extension ShareableWindowDescriptor {
    func with(
        windowID: UInt32,
        title: String? = nil,
        isOnScreen: Bool? = nil,
        isNormalContent: Bool? = nil,
        intersectsMainDisplay: Bool? = nil
    ) -> ShareableWindowDescriptor {
        ShareableWindowDescriptor(
            windowID: windowID,
            processID: processID,
            bounds: bounds,
            title: title ?? self.title,
            isOnScreen: isOnScreen ?? self.isOnScreen,
            isNormalContent: isNormalContent ?? self.isNormalContent,
            intersectsMainDisplay: intersectsMainDisplay ?? self.intersectsMainDisplay
        )
    }
}
