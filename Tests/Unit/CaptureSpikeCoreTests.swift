import CryptoKit
import Foundation
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
            gate.evaluate(
                epochID: epochID, timestampNanoseconds: 0, signature: 1, lastActivityNanoseconds: 0),
            .accepted(index: true, reason: .firstEpochFrame)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID, timestampNanoseconds: 500_000_000, signature: 2,
                lastActivityNanoseconds: 0),
            .rejected(.activeRateLimit)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID, timestampNanoseconds: 1_000_000_000, signature: 2,
                lastActivityNanoseconds: 0),
            .accepted(index: false, reason: .visualChange)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID, timestampNanoseconds: 2_000_000_000, signature: 2,
                lastActivityNanoseconds: 0),
            .rejected(.staticDuplicate)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID, timestampNanoseconds: 31_000_000_000, signature: 2,
                lastActivityNanoseconds: 0),
            .accepted(index: true, reason: .staticHeartbeat)
        )
        XCTAssertEqual(
            gate.evaluate(
                epochID: epochID, timestampNanoseconds: 301_000_000_000, signature: 3,
                lastActivityNanoseconds: 0),
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

    func testMediaWriterCorePlansScopedVariableFrameRateLocatorsAndDownscale() throws {
        let chunkID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let epochID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let scope = MediaChunkScope(
            epochID: epochID,
            targetWindowID: 8,
            dimensions: PixelSize(width: 1_920, height: 1_080),
            startedNanoseconds: 1_000
        )
        var core = try MediaWriterCore(chunkID: chunkID, scope: scope)
        let frameIDs = [
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
        ]

        for (frameID, presentationTime) in zip(frameIDs, [10_000, 10_400, 11_750]) {
            let plan = try core.planAppend(
                frameID: frameID,
                captureEpochID: epochID,
                targetWindowID: 8,
                sourceDimensions: PixelSize(width: 3_840, height: 2_160),
                sourcePresentationTimeMilliseconds: Int64(presentationTime)
            )
            XCTAssertEqual(plan.downscale.destinationDimensions, scope.dimensions)
            XCTAssertTrue(plan.downscale.requiresScaling)
            try core.recordAccepted(plan)
        }

        XCTAssertEqual(core.locators.map(\.frameID), frameIDs)
        XCTAssertEqual(core.locators.map(\.presentationTimeMilliseconds), [0, 400, 1_750])
        XCTAssertEqual(core.durationMilliseconds, 1_750)
        XCTAssertEqual(core.frameCount, 3)
    }

    func testMediaWriterCoreRejectsCrossScopeInvalidGeometryAndUnsafeTiming() throws {
        let epochID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let scope = MediaChunkScope(
            epochID: epochID,
            targetWindowID: 8,
            dimensions: PixelSize(width: 1_920, height: 1_080),
            startedNanoseconds: 1_000
        )
        var core = try MediaWriterCore(chunkID: UUID(), scope: scope)
        let first = try core.planAppend(
            frameID: UUID(),
            captureEpochID: epochID,
            targetWindowID: 8,
            sourceDimensions: scope.dimensions,
            sourcePresentationTimeMilliseconds: 5_000
        )
        try core.recordAccepted(first)

        XCTAssertThrowsError(
            try core.planAppend(
                frameID: UUID(),
                captureEpochID: UUID(),
                targetWindowID: 8,
                sourceDimensions: scope.dimensions,
                sourcePresentationTimeMilliseconds: 6_000
            )
        ) { XCTAssertEqual($0 as? MediaWriterCoreError, .scopeMismatch) }
        XCTAssertThrowsError(
            try core.planAppend(
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 8,
                sourceDimensions: PixelSize(width: 1_920, height: 1_200),
                sourcePresentationTimeMilliseconds: 6_000
            )
        ) { XCTAssertEqual($0 as? MediaWriterCoreError, .aspectRatioMismatch) }
        XCTAssertThrowsError(
            try core.planAppend(
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 8,
                sourceDimensions: scope.dimensions,
                sourcePresentationTimeMilliseconds: 5_000
            )
        ) { XCTAssertEqual($0 as? MediaWriterCoreError, .nonIncreasingPresentationTime) }
        XCTAssertThrowsError(
            try core.planAppend(
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 8,
                sourceDimensions: scope.dimensions,
                sourcePresentationTimeMilliseconds: 35_001
            )
        ) { XCTAssertEqual($0 as? MediaWriterCoreError, .maximumDurationExceeded) }
    }

    func testMediaWriterCoreCommitsLocatorsOnlyAfterMockBackendAcceptance() throws {
        let epochID = UUID()
        let scope = MediaChunkScope(
            epochID: epochID,
            targetWindowID: 8,
            dimensions: PixelSize(width: 1_920, height: 1_080),
            startedNanoseconds: 0
        )
        var core = try MediaWriterCore(chunkID: UUID(), scope: scope)
        let frameID = UUID()
        let rejectedByMockBackend = try core.planAppend(
            frameID: frameID,
            captureEpochID: epochID,
            targetWindowID: 8,
            sourceDimensions: scope.dimensions,
            sourcePresentationTimeMilliseconds: 10_000
        )
        XCTAssertEqual(core.frameCount, 0)

        let acceptedByMockBackend = try core.planAppend(
            frameID: frameID,
            captureEpochID: epochID,
            targetWindowID: 8,
            sourceDimensions: scope.dimensions,
            sourcePresentationTimeMilliseconds: 10_000
        )
        XCTAssertEqual(acceptedByMockBackend, rejectedByMockBackend)
        try core.recordAccepted(acceptedByMockBackend)
        XCTAssertEqual(core.frameCount, 1)
        XCTAssertEqual(core.locators.map(\.frameID), [frameID])
    }

    func testMediaChunkPublisherAtomicallyPublishesOwnerOnlyHashedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm025-publisher-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("chunk.mov")
        let partialURL = MediaChunkPublisher.partialURL(for: outputURL)
        let contents = Data("mock-encoded-chunk".utf8)
        try contents.write(to: partialURL, options: .withoutOverwriting)

        let integrity = try MediaChunkPublisher.publish(
            partialURL: partialURL,
            outputURL: outputURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertEqual(try Data(contentsOf: outputURL), contents)
        XCTAssertEqual(integrity.byteCount, Int64(contents.count))
        XCTAssertEqual(integrity.sha256, Data(SHA256.hash(data: contents)))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testMediaChunkPublisherFaultBoundariesNeverExposePartialAsFinal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm025-faults-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let beforeOutput = root.appendingPathComponent("before.mov")
        let beforePartial = MediaChunkPublisher.partialURL(for: beforeOutput)
        try Data("before".utf8).write(to: beforePartial, options: .withoutOverwriting)
        XCTAssertThrowsError(
            try MediaChunkPublisher.publish(
                partialURL: beforePartial,
                outputURL: beforeOutput,
                fault: .beforeRename
            )
        ) {
            XCTAssertEqual(
                $0 as? MediaChunkPublisherError,
                .injectedFault(.beforeRename)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforePartial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: beforeOutput.path))

        let afterOutput = root.appendingPathComponent("after.mov")
        let afterPartial = MediaChunkPublisher.partialURL(for: afterOutput)
        try Data("after".utf8).write(to: afterPartial, options: .withoutOverwriting)
        XCTAssertThrowsError(
            try MediaChunkPublisher.publish(
                partialURL: afterPartial,
                outputURL: afterOutput,
                fault: .afterRenameBeforeDirectorySync
            )
        ) {
            XCTAssertEqual(
                $0 as? MediaChunkPublisherError,
                .injectedFault(.afterRenameBeforeDirectorySync)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: afterPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterOutput.path))
    }

    func testCapabilityStatusRequiresScreenRecordingAndAccessibility() throws {
        XCTAssertEqual(
            CaptureCapabilityStatus(screenRecording: false, accessibility: false).missing,
            [.screenRecording, .accessibility]
        )
        XCTAssertFalse(CaptureCapabilityStatus(screenRecording: true, accessibility: false).isReady)
        XCTAssertTrue(CaptureCapabilityStatus(screenRecording: true, accessibility: true).isReady)
    }

    func testCaptureGeometryPreservesAspectAndProducesEvenMediaDimensions() throws {
        XCTAssertEqual(
            CaptureGeometry.encodedSize(for: PointRect(x: 0, y: 0, width: 3_840, height: 2_160)),
            PixelSize(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            CaptureGeometry.encodedSize(for: PointRect(x: 0, y: 0, width: 913, height: 641)),
            PixelSize(width: 912, height: 640)
        )
    }

    func testHEICProductionQualityIsExplicitAndBounded() throws {
        XCTAssertEqual(ImageIOHEICFrameEncoder.productionQuality, 0.82)
        XCTAssertTrue((0...1).contains(ImageIOHEICFrameEncoder.productionQuality))
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

extension FrameCandidate {
    fileprivate func with(
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

extension FocusedWindowDescriptor {
    fileprivate func with(isMinimized: Bool) -> FocusedWindowDescriptor {
        FocusedWindowDescriptor(
            processID: processID,
            bounds: bounds,
            title: title,
            isMinimized: isMinimized
        )
    }
}

extension ShareableWindowDescriptor {
    fileprivate func with(
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
