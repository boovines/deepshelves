import AppKit
import ApplicationServices
import Foundation
import MemoryCapture

private struct LM020TransitionRecord: Codable {
    let id: String
    let expected: String
    let actual: String
    let expectedWindowID: UInt32?
    let actualWindowID: UInt32?
    let pixelPayloadCount: Int
}

private struct LM020CorpusEvidence: Codable {
    let seed: UInt64
    let transitionCount: Int
    let approvedCount: Int
    let exactResolutionCount: Int
    let gapCounts: [String: Int]
    let zeroPixelGapCount: Int
    let records: [LM020TransitionRecord]
}

private struct LM020RealProbeEvidence: Codable {
    let accessibilityTrusted: Bool
    let screenRecordingPermission: ScreenRecordingPermission
    let monitorTransitionKind: ForegroundApplicationTransitionKind
    let monitorTransitionSequence: UInt64
    let bundleIdentifier: String
    let foregroundProcessID: Int32
    let axWindowProcessID: Int32
    let axRole: String
    let axSubrole: String?
    let axTitle: String?
    let axIdentitySource: AXWindowIdentitySource
    let axIdentityConfirmed: Bool
    let focusedAndTopLevelGeometryAgree: Bool
    let refreshStatus: ShareableWindowRefreshStatus?
    let resolution: String
    let resolvedWindowID: UInt32?
    let resolvedWindowProcessID: Int32?
    let resolvedMainDisplay: Bool
    let pixelPayloadCount: Int
}

private struct LM020WindowResolverReport: Codable {
    let schemaVersion: Int
    let publicAPIsOnly: Bool
    let foregroundWindowOnly: Bool
    let corpus: LM020CorpusEvidence
    let realProbe: LM020RealProbeEvidence
    let allInvariantsPassed: Bool
}

enum LM020WindowResolverHarnessError: Error {
    case monitorDidNotStart
    case foregroundSnapshotUnavailable(CaptureGapReason)
    case realWindowDidNotResolve(String)
}

@MainActor
enum LM020WindowResolverHarness {
    private static let seed: UInt64 = 1_279_938_620

    static func run(outputURL: URL) async throws {
        NSApplication.shared.activate()
        NSApplication.shared.keyWindow?.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1))

        let monitor = NSWorkspaceForegroundApplicationMonitor()
        var iterator = monitor.transitions().makeAsyncIterator()
        guard let transition = await iterator.next() else {
            throw LM020WindowResolverHarnessError.monitorDidNotStart
        }
        let resolver = ForegroundCaptureTargetResolver()
        let realResolution = await resolver.resolve(transitionSequence: transition.sequence)
        guard case let .available(application, window) = realResolution.snapshot else {
            if case let .gap(reason) = realResolution.snapshot {
                throw LM020WindowResolverHarnessError.foregroundSnapshotUnavailable(reason)
            }
            throw LM020WindowResolverHarnessError.foregroundSnapshotUnavailable(.noWindow)
        }
        guard case let .approved(descriptor) = realResolution.resolution,
              let target = realResolution.target,
              descriptor.windowID == target.windowID,
              target.processID == application.processID
        else {
            throw LM020WindowResolverHarnessError.realWindowDidNotResolve(
                realResolution.resolution.evidenceName
            )
        }

        let corpus = corpusEvidence()
        let permission = await ScreenCaptureKitPermissionProbe().currentPermission()
        let realProbe = LM020RealProbeEvidence(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenRecordingPermission: permission,
            monitorTransitionKind: transition.kind,
            monitorTransitionSequence: transition.sequence,
            bundleIdentifier: application.bundleIdentifier,
            foregroundProcessID: application.processID,
            axWindowProcessID: window.processID,
            axRole: window.role,
            axSubrole: window.subrole,
            axTitle: window.title,
            axIdentitySource: window.identitySource,
            axIdentityConfirmed: window.hasConfirmedAXIdentity,
            focusedAndTopLevelGeometryAgree: window.topLevelBounds == window.bounds,
            refreshStatus: realResolution.refreshStatus,
            resolution: realResolution.resolution.evidenceName,
            resolvedWindowID: target.windowID,
            resolvedWindowProcessID: target.processID,
            resolvedMainDisplay: target.intersectsMainDisplay,
            pixelPayloadCount: realResolution.pixelPayloadCount
        )
        let report = LM020WindowResolverReport(
            schemaVersion: 1,
            publicAPIsOnly: true,
            foregroundWindowOnly: true,
            corpus: corpus,
            realProbe: realProbe,
            allInvariantsPassed: corpus.transitionCount == 500
                && corpus.approvedCount == 350
                && corpus.exactResolutionCount == 500
                && corpus.zeroPixelGapCount == 150
                && realProbe.accessibilityTrusted
                && realProbe.screenRecordingPermission == .granted
                && realProbe.monitorTransitionKind == .initial
                && realProbe.foregroundProcessID == realProbe.axWindowProcessID
                && realProbe.axRole == "AXWindow"
                && realProbe.axIdentityConfirmed
                && realProbe.focusedAndTopLevelGeometryAgree
                && realProbe.refreshStatus == .available
                && realProbe.resolution.hasPrefix("approved:")
                && realProbe.resolvedWindowProcessID == realProbe.foregroundProcessID
                && realProbe.resolvedMainDisplay
                && realProbe.pixelPayloadCount == 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    }

    private static func corpusEvidence() -> LM020CorpusEvidence {
        let transitions = LM020WindowTransitionFixture.make(seed: seed)
        var approvedCount = 0
        var exactCount = 0
        var gapCounts: [String: Int] = [:]
        var zeroPixelGapCount = 0
        let records = transitions.map { transition in
            let actual = WindowResolver.resolve(
                focused: transition.focused,
                candidates: transition.candidates
            )
            if case .approved = actual {
                approvedCount += 1
            }
            if actual == transition.expectedResolution {
                exactCount += 1
            }
            if case let .gap(reason) = actual {
                gapCounts[reason.rawValue, default: 0] += 1
                if transition.pixelPayload == nil {
                    zeroPixelGapCount += 1
                }
            }
            return LM020TransitionRecord(
                id: transition.id,
                expected: transition.expectedResolution.evidenceName,
                actual: actual.evidenceName,
                expectedWindowID: transition.expectedWindowID,
                actualWindowID: actual.windowID,
                pixelPayloadCount: transition.pixelPayload == nil ? 0 : 1
            )
        }
        return LM020CorpusEvidence(
            seed: seed,
            transitionCount: transitions.count,
            approvedCount: approvedCount,
            exactResolutionCount: exactCount,
            gapCounts: gapCounts,
            zeroPixelGapCount: zeroPixelGapCount,
            records: records
        )
    }
}

private extension WindowResolution {
    var windowID: UInt32? {
        guard case let .approved(window) = self else {
            return nil
        }
        return window.windowID
    }

    var evidenceName: String {
        switch self {
        case let .approved(window):
            "approved:\(window.windowID)"
        case let .gap(reason):
            "gap:\(reason.rawValue)"
        }
    }
}
