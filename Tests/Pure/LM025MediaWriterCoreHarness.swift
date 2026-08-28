import CryptoKit
import Foundation

@main
enum LM025MediaWriterCoreHarness {
    static func main() throws {
        if CommandLine.arguments.count == 4,
            CommandLine.arguments[1] == "--termination-child"
        {
            try runTerminationChild(
                partialURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                readyURL: URL(fileURLWithPath: CommandLine.arguments[3])
            )
        }

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
            try require(plan.downscale.destinationDimensions == scope.dimensions, "downscale")
            try require(plan.downscale.requiresScaling, "scaling flag")
            try core.recordAccepted(plan)
        }

        try require(core.locators.map(\.frameID) == frameIDs, "frame identity")
        try require(
            core.locators.map(\.presentationTimeMilliseconds) == [0, 400, 1_750],
            "VFR locators"
        )
        try require(core.durationMilliseconds == 1_750, "duration")
        try require(core.frameCount == 3, "frame count")

        var guardedCore = try MediaWriterCore(chunkID: UUID(), scope: scope)
        let first = try guardedCore.planAppend(
            frameID: UUID(),
            captureEpochID: epochID,
            targetWindowID: 8,
            sourceDimensions: scope.dimensions,
            sourcePresentationTimeMilliseconds: 5_000
        )
        try guardedCore.recordAccepted(first)
        try expect(.scopeMismatch) {
            try guardedCore.planAppend(
                frameID: UUID(),
                captureEpochID: UUID(),
                targetWindowID: 8,
                sourceDimensions: scope.dimensions,
                sourcePresentationTimeMilliseconds: 6_000
            )
        }
        try expect(.aspectRatioMismatch) {
            try guardedCore.planAppend(
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 8,
                sourceDimensions: PixelSize(width: 1_920, height: 1_200),
                sourcePresentationTimeMilliseconds: 6_000
            )
        }
        try expect(.nonIncreasingPresentationTime) {
            try guardedCore.planAppend(
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 8,
                sourceDimensions: scope.dimensions,
                sourcePresentationTimeMilliseconds: 5_000
            )
        }
        try expect(.maximumDurationExceeded) {
            try guardedCore.planAppend(
                frameID: UUID(),
                captureEpochID: epochID,
                targetWindowID: 8,
                sourceDimensions: scope.dimensions,
                sourcePresentationTimeMilliseconds: 35_001
            )
        }

        var backpressureCore = try MediaWriterCore(chunkID: UUID(), scope: scope)
        let backpressureFrameID = UUID()
        let rejectedByMockBackend = try backpressureCore.planAppend(
            frameID: backpressureFrameID,
            captureEpochID: epochID,
            targetWindowID: 8,
            sourceDimensions: scope.dimensions,
            sourcePresentationTimeMilliseconds: 10_000
        )
        try require(backpressureCore.frameCount == 0, "backpressure has no locator")
        let acceptedByMockBackend = try backpressureCore.planAppend(
            frameID: backpressureFrameID,
            captureEpochID: epochID,
            targetWindowID: 8,
            sourceDimensions: scope.dimensions,
            sourcePresentationTimeMilliseconds: 10_000
        )
        try require(
            acceptedByMockBackend == rejectedByMockBackend,
            "backpressure retry is stable"
        )
        try backpressureCore.recordAccepted(acceptedByMockBackend)
        try require(backpressureCore.frameCount == 1, "accepted locator committed once")

        let retention = MediaBufferRetentionLedger<LifetimeProbe>()
        weak var firstRetainedProbe: LifetimeProbe?
        weak var secondRetainedProbe: LifetimeProbe?
        do {
            var first: LifetimeProbe? = LifetimeProbe(id: 1)
            var second: LifetimeProbe? = LifetimeProbe(id: 2)
            firstRetainedProbe = first
            secondRetainedProbe = second
            try retention.retainAccepted(first!)
            try retention.retainAccepted(second!)
            first = nil
            second = nil
        }
        try require(retention.retainedCount == 2, "accepted adaptor buffers retained")
        try require(firstRetainedProbe != nil, "first buffer alive before finalization")
        try require(secondRetainedProbe != nil, "second buffer alive before finalization")
        retention.releaseAfterFinalization()
        try require(retention.retainedCount == 0, "retained buffers released after finalization")
        try require(firstRetainedProbe == nil, "first buffer released after finalization")
        try require(secondRetainedProbe == nil, "second buffer released after finalization")
        try expectRetention(.finalizationCompleted) {
            try retention.retainAccepted(LifetimeProbe(id: 3))
        }

        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm025-publisher-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let outputURL = fixtureRoot.appendingPathComponent("chunk.mov")
        let partialURL = MediaChunkPublisher.partialURL(for: outputURL)
        var softwareEncoder = DeterministicSoftwareFrameEncoder()
        for (frameID, presentationTime) in zip(frameIDs, [0, 400, 1_750]) {
            softwareEncoder.append(
                frameID: frameID,
                presentationTimeMilliseconds: Int64(presentationTime),
                payload: Data("software-frame-\(presentationTime)".utf8)
            )
        }
        let contents = softwareEncoder.finalize()
        try contents.write(to: partialURL, options: .withoutOverwriting)
        let integrity = try MediaChunkPublisher.publish(
            partialURL: partialURL,
            outputURL: outputURL
        )
        try require(!FileManager.default.fileExists(atPath: partialURL.path), "partial removed")
        let publishedContents = try Data(contentsOf: outputURL)
        try require(publishedContents == contents, "published bytes")
        try require(integrity.byteCount == Int64(contents.count), "published byte count")
        try require(
            integrity.sha256 == Data(SHA256.hash(data: contents)),
            "published SHA-256"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        try require(attributes[.posixPermissions] as? Int == 0o600, "owner-only media")
        let finalization = try core.finalization(
            outputURL: outputURL,
            codecFourCC: "hvc1",
            hardwareAccelerationRequired: true,
            integrity: integrity
        )
        try require(finalization.chunkID == chunkID, "final chunk identity")
        try require(finalization.scope == scope, "final scope")
        try require(finalization.frameCount == 3, "final frame count")
        try require(finalization.locators == core.locators, "final locators")
        try require(finalization.byteCount == integrity.byteCount, "final byte count")
        try require(finalization.sha256 == integrity.sha256, "final SHA-256")

        let beforeOutput = fixtureRoot.appendingPathComponent("before.mov")
        let beforePartial = MediaChunkPublisher.partialURL(for: beforeOutput)
        try Data("before".utf8).write(to: beforePartial, options: .withoutOverwriting)
        try expectPublisher(.injectedFault(.beforeRename)) {
            try MediaChunkPublisher.publish(
                partialURL: beforePartial,
                outputURL: beforeOutput,
                fault: .beforeRename
            )
        }
        try require(FileManager.default.fileExists(atPath: beforePartial.path), "before partial")
        try require(!FileManager.default.fileExists(atPath: beforeOutput.path), "before final")

        let afterOutput = fixtureRoot.appendingPathComponent("after.mov")
        let afterPartial = MediaChunkPublisher.partialURL(for: afterOutput)
        try Data("after".utf8).write(to: afterPartial, options: .withoutOverwriting)
        try expectPublisher(.injectedFault(.afterRenameBeforeDirectorySync)) {
            try MediaChunkPublisher.publish(
                partialURL: afterPartial,
                outputURL: afterOutput,
                fault: .afterRenameBeforeDirectorySync
            )
        }
        try require(!FileManager.default.fileExists(atPath: afterPartial.path), "after partial")
        try require(FileManager.default.fileExists(atPath: afterOutput.path), "after final")
        print("LM-025 pure media writer core/software fixture: 6 scenarios passed")
    }

    private static func runTerminationChild(partialURL: URL, readyURL: URL) throws -> Never {
        var encoder = DeterministicSoftwareFrameEncoder()
        for index in 0..<3 {
            encoder.append(
                frameID: UUID(),
                presentationTimeMilliseconds: Int64(index * 1_000),
                payload: Data(repeating: UInt8(index + 1), count: 4_096)
            )
        }
        try encoder.finalize().write(to: partialURL, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.synchronize()
        try handle.close()
        try Data("ready".utf8).write(to: readyURL, options: .withoutOverwriting)
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else {
            throw HarnessError.failed(label)
        }
    }

    private static func expect<T>(
        _ expected: MediaWriterCoreError,
        _ operation: () throws -> T
    ) throws {
        do {
            _ = try operation()
            throw HarnessError.missingError(String(describing: expected))
        } catch let error as MediaWriterCoreError {
            try require(error == expected, "expected \(expected), received \(error)")
        }
    }

    private static func expectPublisher<T>(
        _ expected: MediaChunkPublisherError,
        _ operation: () throws -> T
    ) throws {
        do {
            _ = try operation()
            throw HarnessError.missingError(String(describing: expected))
        } catch let error as MediaChunkPublisherError {
            try require(error == expected, "expected \(expected), received \(error)")
        }
    }

    private static func expectRetention<T>(
        _ expected: MediaBufferRetentionError,
        _ operation: () throws -> T
    ) throws {
        do {
            _ = try operation()
            throw HarnessError.missingError(String(describing: expected))
        } catch let error as MediaBufferRetentionError {
            try require(error == expected, "expected \(expected), received \(error)")
        }
    }
}

private final class LifetimeProbe {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

private struct DeterministicSoftwareFrameEncoder {
    private var bytes = Data("LM025-SOFTWARE-FIXTURE-V1\n".utf8)

    mutating func append(
        frameID: UUID,
        presentationTimeMilliseconds: Int64,
        payload: Data
    ) {
        bytes.append(Data("\(frameID.uuidString),\(presentationTimeMilliseconds),".utf8))
        bytes.append(payload)
        bytes.append(0x0A)
    }

    func finalize() -> Data {
        bytes
    }
}

private enum HarnessError: Error {
    case failed(String)
    case missingError(String)
}
